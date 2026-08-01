#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Redis HA cluster test — stress / latency / failover             ║
# ║  Run against a live cluster installed by install-redis-ha.sh     ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# What it does:
#   1. Stress test  — redis-benchmark against the master (throughput, ops/sec)
#   2. Latency test  — redis-cli --latency-history against the master
#   3. HA/failover test — stops Redis on the current master via SSH, times
#      how long Sentinel takes to promote a replica, confirms the old master
#      rejoins as a replica once restarted
#
# This script only talks to the cluster over the network (redis-cli /
# redis-benchmark) and over SSH to restart the master for the failover test —
# it does not need to run on a cluster node itself.
#
# Usage:
#   ./test-redis-cluster.sh -a <IP_A> -b <IP_B> -c <IP_C> -n <cluster-name> -p '<password>' [options]
#
# Options:
#   -a IP_A            Server A (initial master) IP           [required]
#   -b IP_B             Server B (replica) IP                  [required]
#   -c IP_C             Server C (arbiter) IP                  [required]
#   -n CLUSTER_NAME      Sentinel cluster name                  [required]
#   -p PASSWORD          Redis password (plain text)             [required]
#   -u SSH_USER          SSH user for the failover test          [default: root]
#   -k                    Skip the failover test (stress+latency only, no SSH needed)
#   -r REQUESTS           redis-benchmark request count           [default: 100000]
#   -C CLIENTS            redis-benchmark parallel clients         [default: 50]
#   -h                    Show this help
#
# Example:
#   ./test-redis-cluster.sh -a 10.0.0.1 -b 10.0.0.2 -c 10.0.0.3 -n mycluster -p 'MyStrongPass'

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${BLUE}══ $* ══${NC}"; }

SSH_USER="root"
SKIP_FAILOVER=0
BENCH_REQUESTS=100000
BENCH_CLIENTS=50
IP_A=""; IP_B=""; IP_C=""; CLUSTER_NAME=""; PASSWORD=""

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while getopts "a:b:c:n:p:u:r:C:kh" opt; do
    case "$opt" in
        a) IP_A="$OPTARG" ;;
        b) IP_B="$OPTARG" ;;
        c) IP_C="$OPTARG" ;;
        n) CLUSTER_NAME="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        r) BENCH_REQUESTS="$OPTARG" ;;
        C) BENCH_CLIENTS="$OPTARG" ;;
        k) SKIP_FAILOVER=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$IP_A" ] || [ -z "$IP_B" ] || [ -z "$IP_C" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$PASSWORD" ]; then
    err "Missing required arguments."
    usage
fi

for cmd in redis-cli redis-benchmark; do
    command -v "$cmd" >/dev/null 2>&1 || { err "$cmd not found. Install redis-tools on the machine running this script."; exit 1; }
done

FAIL=0
RCLI_A=(redis-cli -h "$IP_A" -p 6379 -a "$PASSWORD" --no-auth-warning)
RCLI_B=(redis-cli -h "$IP_B" -p 6379 -a "$PASSWORD" --no-auth-warning)
SENT_A=(redis-cli -h "$IP_A" -p 26379)
SENT_B=(redis-cli -h "$IP_B" -p 26379)
SENT_C=(redis-cli -h "$IP_C" -p 26379)

# ═══════════════════════════════════════════════════════════════════
# 0. Basic reachability
# ═══════════════════════════════════════════════════════════════════
step "0. Reachability check"

CURRENT_MASTER=$("${SENT_A[@]}" SENTINEL get-master-addr-by-name "$CLUSTER_NAME" 2>/dev/null | head -1)
if [ -z "$CURRENT_MASTER" ]; then
    err "Could not get the master address from Sentinel on $IP_A. Is the cluster up? Is CLUSTER_NAME correct?"
    exit 1
fi
log "Sentinel reports current master: $CURRENT_MASTER"

if [ "$("${RCLI_A[@]}" -h "$CURRENT_MASTER" ping 2>/dev/null)" != "PONG" ]; then
    err "Master at $CURRENT_MASTER did not answer PING."
    FAIL=1
else
    log "Master PING OK"
fi

# ═══════════════════════════════════════════════════════════════════
# 1. Stress test (throughput)
# ═══════════════════════════════════════════════════════════════════
step "1. Stress test — redis-benchmark against master ($CURRENT_MASTER)"
log "Requests: $BENCH_REQUESTS, parallel clients: $BENCH_CLIENTS"

# NOTE: redis-benchmark does not understand --no-auth-warning (that flag is
# redis-cli only) — passing it makes redis-benchmark bail out on an unknown option.
redis-benchmark -h "$CURRENT_MASTER" -p 6379 -a "$PASSWORD" \
    -n "$BENCH_REQUESTS" -c "$BENCH_CLIENTS" -q \
    -t set,get,incr,lpush,rpop,hset,spop \
    || { err "redis-benchmark failed"; FAIL=1; }

# ═══════════════════════════════════════════════════════════════════
# 2. Latency test
# ═══════════════════════════════════════════════════════════════════
step "2. Latency test — sampling for 10s against master ($CURRENT_MASTER)"

# --latency-history prints "min max avg count" per sample (no field labels),
# followed by a "-- N.NN seconds range" marker at the end of each window.
# Keep only complete "min max avg count" lines — the very last line can be
# cut off mid-write by `timeout`, and the "-- ... range" lines aren't data.
LATENCY_RAW=$(timeout 11 redis-cli -h "$CURRENT_MASTER" -p 6379 -a "$PASSWORD" --no-auth-warning --latency-history -i 1 2>/dev/null | \
    grep -E '^[0-9.]+ [0-9.]+ [0-9.]+ [0-9]+$' || true)
echo "$LATENCY_RAW" | tail -5
LAST_SAMPLE=$(echo "$LATENCY_RAW" | tail -1)
[ -n "$LAST_SAMPLE" ] && log "min/max/avg/samples (last window): $LAST_SAMPLE"

LATENCY_AVG=$(echo "$LAST_SAMPLE" | awk '{print $3}')
if [ -n "$LATENCY_AVG" ]; then
    # Kamailio does synchronous Redis lookups on the SIP signaling path (usrloc/auth/dialog) —
    # anything above a few ms here starts to show up as call-setup delay.
    if awk "BEGIN{exit !($LATENCY_AVG > 5)}"; then
        warn "Average latency ${LATENCY_AVG}ms is high for a Kamailio-backing Redis (>5ms). Check network RTT, CPU steal, and maxmemory eviction pressure."
    else
        log "Average latency: ${LATENCY_AVG}ms — OK for SIP signaling use"
    fi
else
    warn "Could not parse average latency from redis-cli output."
fi

echo ""
log "Intrinsic (scheduler) latency check on master host itself, run manually if needed:"
echo "  ssh ${SSH_USER}@${CURRENT_MASTER} redis-cli --intrinsic-latency 5"

# ═══════════════════════════════════════════════════════════════════
# 3. HA / failover test
# ═══════════════════════════════════════════════════════════════════
if [ "$SKIP_FAILOVER" -eq 1 ]; then
    warn "Skipping failover test (-k given)."
else
    step "3. HA/failover test"

    if ! command -v ssh >/dev/null 2>&1; then
        warn "ssh not found — skipping failover test. Re-run without -k on a machine with SSH access to the cluster."
    else
        # Only use sudo when logging in as non-root — sudo may not even be installed
        # on minimal images, and root doesn't need it (nor does it hurt to skip it).
        REMOTE_STOP='if [ "$(id -u)" = "0" ]; then systemctl stop redis-server 2>/dev/null || systemctl stop redis 2>/dev/null; else sudo systemctl stop redis-server 2>/dev/null || sudo systemctl stop redis 2>/dev/null; fi'
        REMOTE_START='if [ "$(id -u)" = "0" ]; then systemctl start redis-server 2>/dev/null || systemctl start redis 2>/dev/null; else sudo systemctl start redis-server 2>/dev/null || sudo systemctl start redis 2>/dev/null; fi'

        OLD_MASTER="$CURRENT_MASTER"
        log "Stopping Redis on current master ($OLD_MASTER) via SSH..."
        if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${SSH_USER}@${OLD_MASTER}" "$REMOTE_STOP"; then
            err "Could not stop Redis on $OLD_MASTER via SSH. Check SSH access (-u to change user) or run manually and use -k."
            FAIL=1
        else
            log "Redis stopped on $OLD_MASTER. Waiting for Sentinel to promote a replica..."
            START_TS=$(date +%s)
            NEW_MASTER=""
            for _ in $(seq 1 30); do
                CANDIDATE=$("${SENT_C[@]}" SENTINEL get-master-addr-by-name "$CLUSTER_NAME" 2>/dev/null | head -1)
                if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$OLD_MASTER" ]; then
                    NEW_MASTER="$CANDIDATE"
                    break
                fi
                sleep 1
            done
            END_TS=$(date +%s)

            if [ -n "$NEW_MASTER" ]; then
                log "Failover complete in $((END_TS - START_TS))s — new master: $NEW_MASTER"
                if [ "$("${RCLI_A[@]}" -h "$NEW_MASTER" ping 2>/dev/null)" = "PONG" ]; then
                    log "New master answers PING — cluster is writable again"
                else
                    err "New master $NEW_MASTER does not answer PING"
                    FAIL=1
                fi
            else
                err "No failover after 30s. Check: sentinel down-after-milliseconds / quorum / connectivity between Sentinels."
                FAIL=1
            fi

            log "Restarting Redis on old master ($OLD_MASTER), it should rejoin as a replica..."
            ssh -o ConnectTimeout=5 "${SSH_USER}@${OLD_MASTER}" "$REMOTE_START" || warn "Could not restart Redis on $OLD_MASTER via SSH — restart it manually."

            REJOINED=0
            for _ in $(seq 1 20); do
                ROLE=$("${RCLI_A[@]}" -h "$OLD_MASTER" INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
                if [ "$ROLE" = "slave" ]; then
                    REJOINED=1
                    break
                fi
                sleep 1
            done
            if [ "$REJOINED" -eq 1 ]; then
                log "Old master ($OLD_MASTER) rejoined the cluster as a replica"
            else
                warn "Old master ($OLD_MASTER) has not rejoined as a replica yet after 20s — check its logs (/var/log/redis/redis.log)."
            fi
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════
step "Summary"
if [ "$FAIL" -eq 0 ]; then
    log "All checks passed."
    exit 0
else
    err "One or more checks failed — see above."
    exit 1
fi
