---
tags:
  - redis
  - sentinel
  - prometheus
  - monitoring
  - kamailio
---

# Monitoring the Redis HA cluster with Prometheus

Uses [`redis_exporter`](https://github.com/oliver006/redis_exporter) (the de
facto standard Prometheus exporter for Redis) — one instance per node,
scraping the local Redis and/or Sentinel over `localhost`. It also has native
support for exporting Sentinel-specific metrics.

## 1. Install redis_exporter (systemd, all 3 nodes)

Run it as a sidecar on every node, pointed at the services running locally.

```bash
# Resolves whatever the current release actually is instead of hardcoding a version
# that will go stale — check https://github.com/oliver006/redis_exporter/releases if you'd rather pin one.
REDIS_EXPORTER_VERSION=$(curl -fsSL https://api.github.com/repos/oliver006/redis_exporter/releases/latest | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
ARCH="amd64"                        # or arm64

curl -fsSL -o /tmp/redis_exporter.tar.gz \
  "https://github.com/oliver006/redis_exporter/releases/download/${REDIS_EXPORTER_VERSION}/redis_exporter-${REDIS_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
tar xzf /tmp/redis_exporter.tar.gz -C /tmp
install -m 0755 /tmp/redis_exporter-*.linux-${ARCH}/redis_exporter /usr/local/bin/redis_exporter

useradd --system --no-create-home --shell /usr/sbin/nologin redis_exporter || true
```

### Instance 1 — exports Redis metrics (skip on a `sentinel-only` arbiter with no Redis)

`/etc/systemd/system/redis_exporter.service`:

```ini
[Unit]
Description=Prometheus exporter for Redis
After=redis-server.service redis.service

[Service]
User=redis_exporter
Environment=REDIS_ADDR=redis://127.0.0.1:6379
Environment=REDIS_PASSWORD=YOUR_STRONG_PASSWORD
ExecStart=/usr/local/bin/redis_exporter \
    --web.listen-address=:9121 \
    --redis.addr=${REDIS_ADDR} \
    --redis.password=${REDIS_PASSWORD}
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Instance 2 — exports Sentinel metrics (all 3 nodes, including the arbiter)

`/etc/systemd/system/redis_exporter_sentinel.service`:

```ini
[Unit]
Description=Prometheus exporter for Redis Sentinel
After=redis-sentinel.service

[Service]
User=redis_exporter
ExecStart=/usr/local/bin/redis_exporter \
    --web.listen-address=:9122 \
    --redis.addr=redis://127.0.0.1:26379
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Sentinel has no password (see [`install-redis-ha.sh`](install-redis-ha.sh) —
deliberately no `requirepass` on Sentinel, see the comment in the sentinel.conf
template for why), so no `--redis.password` needed for the Sentinel exporter.

```bash
systemctl daemon-reload
systemctl enable --now redis_exporter               # skip on the arbiter if CONFIG_C_MODE=sentinel-only
systemctl enable --now redis_exporter_sentinel
```

Firewall: open 9121/9122 (or whatever ports you pick) from your Prometheus
server's IP only — same pattern as the `6379`/`26379` rules the install script
already sets up.

## 2. Prometheus scrape config

```yaml
scrape_configs:
  - job_name: redis
    static_configs:
      - targets: ["<IP_A>:9121"]
        labels: { instance_role: master_or_replica, node: A }
      - targets: ["<IP_B>:9121"]
        labels: { instance_role: master_or_replica, node: B }
      # Only if CONFIG_C_MODE=full — remove this line for a sentinel-only arbiter:
      - targets: ["<IP_C>:9121"]
        labels: { instance_role: master_or_replica, node: C }

  - job_name: redis-sentinel
    static_configs:
      - targets: ["<IP_A>:9122", "<IP_B>:9122", "<IP_C>:9122"]
```

## 3. Metrics that actually matter for this setup

This Redis is Kamailio's usrloc/auth/dialog **datastore**, not a cache — the
metrics worth alerting on reflect that (silent data loss is worse than an
outage you can see).

| Metric | Why it matters here |
|---|---|
| `redis_up` | Exporter can't reach Redis/Sentinel at all. |
| `redis_memory_used_bytes` / `redis_config_maxmemory` | This cluster runs `maxmemory-policy allkeys-lru` (a deliberate choice — see [[project-redis-ha-kamailio]] in memory). Watch usage as a % of maxmemory; you want to catch this *before* eviction starts, not after. |
| `redis_evicted_keys_total` (as a rate) | **The most important alert in this whole setup.** With `allkeys-lru`, Redis evicts *any* key under memory pressure — including active SIP registrations. `rate(redis_evicted_keys_total[5m]) > 0` means Kamailio may be silently losing usrloc/dialog entries right now, with no error on the Kamailio side. |
| `redis_connected_slaves` (on the master) | Should be 1 (arbiter mode) or 2 (`CONFIG_C_MODE=full`). A drop means a replica fell behind or died. |
| `redis_master_link_status` / `redis_slave_repl_offset` vs `redis_master_repl_offset` | Replication health and lag on replicas. |
| `redis_connected_clients` | Kamailio holds persistent connections; a sudden spike/drop usually means Kamailio is reconnecting (worth correlating with Kamailio's own logs). |
| `redis_commands_processed_total` / `redis_instantaneous_ops_per_sec` | Baseline throughput; compare against `test-redis-cluster.sh` benchmark numbers to spot degradation over time. |
| `redis_keyspace_hits_total` / `redis_keyspace_misses_total` | A rising miss ratio on a usrloc lookup workload can indicate premature eviction even before `redis_evicted_keys_total` trends alarmingly. |
| `redis_sentinel_masters` / `redis_sentinel_master_ok_sentinels` / `redis_sentinel_master_ok_slaves` (from the Sentinel-mode exporter) | Quorum health. `ok_sentinels` dropping below 2 means a failover would not be able to reach quorum=2 if the master died right now. |
| `redis_sentinel_master_status` | Sentinel's view of whether the master is currently reachable. |

## 4. Example Prometheus alerting rules

```yaml
groups:
  - name: redis-kamailio
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "Redis/Sentinel exporter target down ({{ $labels.instance }})"

      - alert: RedisEvictingKeys
        expr: rate(redis_evicted_keys_total[5m]) > 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Redis is evicting keys on {{ $labels.instance }} — with allkeys-lru this can mean active Kamailio registrations/dialogs are being silently dropped"

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_config_maxmemory > 0.85
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "Redis memory usage above 85% of maxmemory on {{ $labels.instance }}"

      - alert: RedisReplicationDown
        expr: redis_connected_slaves < 1
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Redis master {{ $labels.instance }} has no connected replicas"

      - alert: RedisReplicationBroken
        expr: redis_slave_repl_offset > 0 and (redis_master_repl_offset - redis_slave_repl_offset) > 1000000
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "Replica {{ $labels.instance }} is falling behind the master (>1MB offset gap)"

      - alert: SentinelQuorumAtRisk
        expr: redis_sentinel_master_ok_sentinels < 2
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Sentinel on {{ $labels.instance }} only sees {{ $value }} other healthy sentinel(s) — quorum=2 would not be reachable if the master died now"

      - alert: SentinelMasterNotOk
        expr: redis_sentinel_master_status != 1
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "Sentinel {{ $labels.instance }} does not consider the master healthy"
```

Adjust the `redis_slave_repl_offset` / `redis_master_repl_offset` threshold
(1MB here) to your actual write rate — a Kamailio cluster with a lot of
registration churn will produce more replication bytes/sec than a quiet one.

## 5. Latency

`redis_exporter` doesn't sample end-to-end command latency well by default
(`redis_commands_duration_seconds_total` exists but is a cumulative counter,
not a live gauge). For actual latency numbers on demand, use:

```bash
redis-cli -h <IP> -a '<password>' --no-auth-warning --latency-history -i 5
```

or run [`test-redis-cluster.sh`](test-redis-cluster.sh) periodically (e.g. from
a cron job or a scheduled CI pipeline) — it already does a stress test +
latency sample + a full failover drill and exits non-zero on failure, so it
can be wired into an existing monitoring/CI system as a synthetic check
independent of Prometheus.

## 6. Grafana

The community "Redis Dashboard for Prometheus Redis Exporter" (dashboard ID
**11835** on grafana.com) works out of the box against these metrics and
already has panels for memory, evictions, replication, and ops/sec.
