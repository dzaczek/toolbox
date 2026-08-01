---
data: 2026-07-31
tags:
  - redis
  - sentinel
  - ha
  - kamailio
  - infrastructure
  - script
---

# Redis HA with Sentinel — 2× Redis + arbiter (3 servers)

## Architecture

```
┌─ Server A ───────────────────┐   ┌─ Server B ───────────────────┐
│  Redis :6379 — MASTER (RW)   │   │  Redis :6379 — REPLICA (RO)  │
│  Sentinel :26379              │   │  Sentinel :26379              │
└──────────┬───────────────────┘   └──────────┬───────────────────┘
           │          replication ↕           │
           └──────────────┬──────────────────┘
                          │
           ┌─ Server C (arbiter) ────────────┐
           │  Sentinel :26379                │
           │  (no Redis, ~100 MB RAM)        │
           └─────────────────────────────────┘

              Quorum = 2 (3 votes)
     Any single server failing → failover still works
```

**Why a separate arbiter instead of a second Sentinel on Server A?**
- Server A fails → with 2 Sentinels on A and 1 on B: quorum=2 unreachable → **no failover**
- With a separate arbiter: A fails → B + C still have 2 votes → **failover works**
- The arbiter can be the cheapest VPS available (512 MB RAM, 1 vCPU, ~€3-5/month)

**What this setup gives you:**
- Continuous master → replica replication
- Automatic failover in ~5-10s
- Resilience against any single server failing
- Clients always reach the RW master through the Sentinel API

---

# Automated installation (script)

## Generating the configuration

```bash
# Generate a password and base64-encode it:
echo -n "YourStrongPasswordMin32Chars" | base64
```

## Script header — only edit these 4 lines

```bash
CONFIG_PASS_B64="VE9KRV9TSUxORV9IQVNMT19UVVRBSg=="   # ← base64 password
CONFIG_IP_A="10.0.0.1"   # ← Redis + Sentinel
CONFIG_IP_B="10.0.0.2"   # ← Redis + Sentinel
CONFIG_IP_C="10.0.0.3"   # ← Sentinel only (arbiter)
```

## Upload and run

```bash
# Upload to all 3 servers:
scp install-redis-ha.sh root@10.0.0.1:/tmp/
scp install-redis-ha.sh root@10.0.0.2:/tmp/
scp install-redis-ha.sh root@10.0.0.3:/tmp/

# Run on each machine:
ssh root@10.0.0.1 "bash /tmp/install-redis-ha.sh"
ssh root@10.0.0.2 "bash /tmp/install-redis-ha.sh"
ssh root@10.0.0.3 "bash /tmp/install-redis-ha.sh"
```

**The script automatically:**
- Detects the server's role by IP (or asks)
- Installs Redis + Sentinel (or just Sentinel on the arbiter)
- Configures **Redis in-memory only** (`save ""`, `appendonly no`) — zero disk writes
- Sets up the firewall (ufw or firewalld)
- Verifies the install and prints ready-to-use Kamailio configuration

---

## Step 1: Install Redis + Sentinel (Servers A and B)

### Both machines:

```bash
# Official Redis repository (recommended, latest version)
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
sudo apt update
sudo apt install -y redis redis-sentinel

# Verify
redis-cli ping        # → PONG
redis-server --version
```

## Step 1b: Install Sentinel only (Server C — arbiter)

```bash
sudo apt install -y redis-sentinel
# Stop redis-server if it got installed as a dependency:
sudo systemctl stop redis-server 2>/dev/null
sudo systemctl disable redis-server 2>/dev/null
```

> Service name note: on Debian/Ubuntu (packages.redis.io repo) the service is
> called `redis-server`, NOT `redis`. On RHEL/Rocky/Alma it's the opposite —
> the service is called `redis`. `systemctl restart redis` on Debian returns
> "Unit redis.service not found" and aborts the script.

## Step 1c: RHEL / Rocky Linux / AlmaLinux (8 and 9)

The distro's default repositories have **not shipped** a current Redis for a
while now (replaced by Valkey after the license change). You need to add the
official `packages.redis.io` repo:

```bash
# Rocky/Alma 9 → rockylinux9, Rocky/Alma 8 → rockylinux8
sudo tee /etc/yum.repos.d/redis.repo <<'EOF'
[Redis]
name=Redis
baseurl=http://packages.redis.io/rpm/rockylinux9
enabled=1
gpgcheck=1
EOF

curl -fsSL https://packages.redis.io/gpg > /tmp/redis.key
sudo rpm --import /tmp/redis.key
sudo dnf install -y redis
sudo dnf install -y redis-sentinel   # if available as a separate package

sudo systemctl enable redis
sudo systemctl start redis
```

---

## Step 2: Configure Redis — Server A (MASTER)

`/etc/redis/redis.conf`:

```ini
# bind to the server's own IP + loopback — NOT 0.0.0.0 (avoid exposing it to the world)
bind <SERVER_A_IP> 127.0.0.1
protected-mode yes
port 6379
daemonize no
supervised systemd
loglevel notice
logfile /var/log/redis/redis.log
dir /var/lib/redis

# ═══ IN-MEMORY ONLY — no disk writes ═══
save ""
appendonly no

# Password — THE SAME on every server
requirepass "YOUR_STRONG_PASSWORD"
masterauth "YOUR_STRONG_PASSWORD"

# Memory limit — adjust to the machine's RAM (e.g. ~70% of total, headroom for OS/Sentinel/fork)
maxmemory 1400mb
maxmemory-policy allkeys-lru

# Network / performance
tcp-keepalive 300
tcp-backlog 511

# Disabled dangerous commands
rename-command FLUSHALL ""
rename-command FLUSHDB ""

# Do NOT set replicaof on the master
```

## Step 3: Configure Redis — Server B (REPLICA)

Identical to the above PLUS:

```ini
# Point to the master
replicaof <SERVER_A_IP> 6379
masterauth "YOUR_STRONG_PASSWORD"

# Read-only
replica-read-only yes
```

### Restart Redis on A and B:

```bash
# Debian/Ubuntu: service "redis-server". RHEL/Rocky/Alma: service "redis".
sudo systemctl restart redis-server   # RHEL: redis
sudo systemctl enable redis-server    # RHEL: redis
```

### Kernel tuning (all 3 servers, recommended by Redis)

```bash
# Transparent Huge Pages — disable, causes latency spikes on fork()/replication
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
# (persist via a systemd oneshot service or rc.local so it survives a reboot)

# vm.overcommit_memory=1 — required by fork() during a full replica resync
# net.core.somaxconn — accept() queue, must be >= tcp-backlog
sudo tee /etc/sysctl.d/99-redis.conf <<'EOF'
vm.overcommit_memory = 1
net.core.somaxconn = 511
EOF
sudo sysctl -p /etc/sysctl.d/99-redis.conf
```

### Verify replication:

```bash
# On A (master):
redis-cli -a "PASSWORD" INFO replication | grep -E "role|connected_slaves"
# → role:master, connected_slaves:1

# On B (replica):
redis-cli -a "PASSWORD" INFO replication | grep -E "role|master_link_status"
# → role:slave, master_link_status:up
```

---

## Step 4: Configure Sentinel (all 3 servers)

**THE SAME configuration on A, B and C** — `/etc/redis/sentinel.conf`:

```ini
bind <THIS_SERVER_IP> 127.0.0.1
# Do NOT set protected-mode yes here — Sentinel has no requirepass, so (unlike
# redis-server) it does NOT get exempted from protected-mode by an explicit
# "bind" and will start rejecting connections from other Sentinels, which
# silently breaks failover. Port 26379 is secured by bind + firewall (Step 6).
port 26379
daemonize no
supervised systemd
logfile /var/log/redis/sentinel.log
dir /var/lib/redis

# Monitor the cluster
sentinel monitor mycluster <SERVER_A_IP> 6379 2
sentinel auth-pass mycluster "YOUR_STRONG_PASSWORD"

sentinel down-after-milliseconds mycluster 5000
sentinel failover-timeout mycluster 15000
sentinel parallel-syncs mycluster 1

sentinel resolve-hostnames no
sentinel announce-hostnames no
```

> Sentinel automatically discovers the other Sentinels and replicas through the master.

### Start it:

```bash
sudo systemctl enable redis-sentinel
sudo systemctl restart redis-sentinel
```

### Verify:

```bash
redis-cli -p 26379 SENTINEL master mycluster | grep -E "ip|port|flags|num-slaves"
redis-cli -p 26379 SENTINEL sentinels mycluster | grep -c "name"
# → 2 (2 others = 3 total)
```

---

## Step 5: Failover test

```bash
# Kill the master:
ssh redis-srv1 "sudo systemctl stop redis"

# Watch the switch happen:
redis-cli -p 26379 SUBSCRIBE +switch-master

# Check the new master:
redis-cli -h <IP_B> -p 26379 SENTINEL get-master-addr-by-name mycluster

# Bring A back — it will rejoin as a replica:
ssh redis-srv1 "sudo systemctl start redis"
redis-cli -h <IP_A> -a "PASSWORD" INFO replication | grep role
# → role:slave
```

For an automated version of this test (stress test + latency + failover, with
pass/fail output), see [`test-redis-cluster.sh`](test-redis-cluster.sh).

---

## Step 6: Firewall

### Debian/Ubuntu (ufw)

```bash
# Server A
sudo ufw allow from <IP_B> to any port 6379,26379
sudo ufw allow from <IP_C> to any port 26379

# Server B
sudo ufw allow from <IP_A> to any port 6379,26379
sudo ufw allow from <IP_C> to any port 26379

# Server C
sudo ufw allow from <IP_A> to any port 26379
sudo ufw allow from <IP_B> to any port 26379
```

### RHEL/Rocky/Alma (firewalld)

```bash
# Server A
sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=<IP_B> port port=6379 protocol=tcp accept"
sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=<IP_B> port port=26379 protocol=tcp accept"
sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=<IP_C> port port=26379 protocol=tcp accept"
sudo firewall-cmd --reload
# Same pattern for Server B and C, with the matching IPs/ports as in the ufw section above.
```

> If no firewall is active, ports 6379/26379 are reachable from any host with
> network access to the machine — secure this with a firewall or a cloud
> security group, `requirepass` alone is not enough.

---

## Step 7: Kamailio — integrating with Redis Sentinel

### db_redis (usrloc, auth, dialog)

```c
loadmodule "db_redis.so"

modparam("db_redis", "with_sentinels", 1)
modparam("db_redis", "sentinels_config",
    "<IP_A>:26379,<IP_B>:26379,<IP_C>:26379")
modparam("db_redis", "redis_master_name", "mycluster")
modparam("db_redis", "db_pass", "YOUR_STRONG_PASSWORD")

modparam("db_redis", "schema_path", "/usr/share/kamailio/db_redis/kamailio")
modparam("db_redis", "keys", "version=entry:table_name")
modparam("db_redis", "keys", "location=entry:ruid&usrdom:username,domain&timer:partition,keepalive")
modparam("db_redis", "keys", "subscriber=entry:username,domain")
modparam("db_redis", "keys", "dialog=entry:hash_entry,hash_id&cid:callid")

# Optional — read from replicas
modparam("db_redis", "use_replicas", 1)
modparam("db_redis", "recheck_replicas_interval", 120)

modparam("usrloc",   "db_url", "redis://<IP_A>:6379/5")
modparam("auth_db",  "db_url", "redis://<IP_A>:6379/7")
modparam("dialog",   "db_url", "redis://<IP_A>:6379/9")
```

### ndb_redis (custom commands)

```c
loadmodule "ndb_redis.so"

# Master (RW)
modparam("ndb_redis", "server",
    "name=redis_master;sentinel_group=mycluster;sentinel_master=1;"
    "sentinel=<IP_A>:26379;sentinel=<IP_B>:26379;sentinel=<IP_C>:26379")

# Replica (RO)
modparam("ndb_redis", "server",
    "name=redis_slave;sentinel_group=mycluster;sentinel_master=0;"
    "sentinel=<IP_A>:26379;sentinel=<IP_B>:26379;sentinel=<IP_C>:26379")
```

---

## Step 8: Python / Node.js / Go clients

### Python (redis-py):
```python
from redis import Sentinel

sentinel = Sentinel([
    ('<IP_A>', 26379), ('<IP_B>', 26379), ('<IP_C>', 26379),
], socket_timeout=0.5)

master = sentinel.master_for('mycluster', password='PASSWORD', decode_responses=True)
master.set('key', 'value')

slave = sentinel.slave_for('mycluster', password='PASSWORD', decode_responses=True)
val = slave.get('key')
```

### Node.js (ioredis):
```javascript
const Redis = require('ioredis');
const redis = new Redis({
  sentinels: [
    { host: '<IP_A>', port: 26379 },
    { host: '<IP_B>', port: 26379 },
    { host: '<IP_C>', port: 26379 },
  ],
  name: 'mycluster', password: 'PASSWORD',
});
```

### Go (go-redis):
```go
rdb := redis.NewFailoverClient(&redis.FailoverOptions{
    MasterName:    "mycluster",
    SentinelAddrs: []string{"<IP_A>:26379", "<IP_B>:26379", "<IP_C>:26379"},
    Password:      "PASSWORD",
})
```

---

## Step 9: Testing (stress / latency / HA)

See [`test-redis-cluster.sh`](test-redis-cluster.sh) — runs a `redis-benchmark`
throughput/stress test, a latency check (`redis-cli --latency-history`), and an
automated failover test (stops the master, times the promotion, confirms the
old master rejoins as a replica) against a live cluster. Usage:

```bash
./test-redis-cluster.sh -a <IP_A> -b <IP_B> -c <IP_C> -n mycluster -p 'YOUR_STRONG_PASSWORD'
```

## Step 10: Monitoring

See [`monitoring-prometheus.md`](monitoring-prometheus.md) for wiring this
cluster up to Prometheus (redis_exporter for Redis + Sentinel, key metrics to
alert on for a Kamailio-backing Redis, and example alerting rules).

---

## Summary

| Component | Server A | Server B | Server C (arbiter) |
|-----------|----------|----------|---------------------|
| Redis | ✅ :6379 | ✅ :6379 | ❌ |
| Sentinel | ✅ :26379 | ✅ :26379 | ✅ :26379 |
| RAM | 2 GB (maxmemory 1400mb) | 2 GB (maxmemory 1400mb) | ~100-512 MB |
| Role | master/replica | replica/master | voter |

**Redis runs in-memory only** — `save ""`, `appendonly no`. Zero disk writes; after a restart Redis starts empty and syncs from the master via replication.

**Why 3 physical servers:** a host failing while running 2 Sentinels kills the quorum → no failover. A separate arbiter = real HA.

**Kamailio supports Sentinel natively in both modules** — no external proxy needed.
