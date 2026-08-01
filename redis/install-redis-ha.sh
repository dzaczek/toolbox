#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Redis HA + Sentinel — auto-install (3-server cluster)          ║
# ║  Upload this file to each of the 3 servers and run it as root   ║
# ║  The script detects its own role by IP and configures itself    ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Usage:
#   1. Set the variables below (base64 password, IPs of the three servers)
#   2. Copy the script to Server A, B and C
#   3. On each machine: chmod +x install-redis-ha.sh && sudo ./install-redis-ha.sh
#
# ═══════════════════════════════════════════════════════════════════
# CONFIGURATION — only change the values below
# ═══════════════════════════════════════════════════════════════════

# Redis password — base64-encoded (generate with: echo -n "YourPassword" | base64)
# All CONFIG_* values can also be overridden via environment variable (e.g. for
# Docker testing) — the values below are just the fallback when the
# corresponding variable isn't already set in the environment.
CONFIG_PASS_B64="${CONFIG_PASS_B64:-VE9KRV9TSUxORV9IQVNMT19UVVRBSg==}"   # ← CHANGE THIS!

# IPs of the three servers
CONFIG_IP_A="${CONFIG_IP_A:-10.0.0.1}"   # ← CHANGE! Redis + Sentinel
CONFIG_IP_B="${CONFIG_IP_B:-10.0.0.2}"   # ← CHANGE! Redis + Sentinel
CONFIG_IP_C="${CONFIG_IP_C:-10.0.0.3}"   # ← CHANGE! Sentinel (+ Redis if CONFIG_C_MODE=full below)

# Cluster name (used by Sentinel and clients)
CONFIG_CLUSTER_NAME="${CONFIG_CLUSTER_NAME:-mycluster}"

# Redis memory limit on Redis nodes — adjust to the machine's real RAM.
# Leave headroom for the OS, Sentinel, and fork() during a full replica resync.
CONFIG_MAXMEMORY="${CONFIG_MAXMEMORY:-1400mb}"   # ← assumes 2GB RAM servers; change if different

# Server C mode:
#   "sentinel-only" (default) — C is a lightweight arbiter: Sentinel only, no Redis data,
#                                minimal RAM (~100-512MB VPS is enough).
#   "full"                    — C also runs Redis as a second replica of A (3 full Redis
#                                nodes + 3 Sentinels), for an extra data copy / read replica
#                                at the cost of needing real RAM (size via CONFIG_MAXMEMORY)
#                                on C as well.
CONFIG_C_MODE="${CONFIG_C_MODE:-sentinel-only}"   # ← "sentinel-only" or "full"

# ═══════════════════════════════════════════════════════════════════
# Don't edit below this line — the script handles the rest automatically
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# -------------------------------------------------------------------
# Decode configuration
# -------------------------------------------------------------------
DEFAULT_PASS_B64="VE9KRV9TSUxORV9IQVNMT19UVVRBSg=="
if [ "$CONFIG_PASS_B64" = "$DEFAULT_PASS_B64" ]; then
    err "CONFIG_PASS_B64 is still the default placeholder from the example. Set your own password: echo -n 'YourStrongPassword' | base64"
fi

CONFIG_PASS=$(echo "$CONFIG_PASS_B64" | base64 -d 2>/dev/null) || {
    err "Could not decode the password from base64. Check CONFIG_PASS_B64."
}

# Validate password length
if [ ${#CONFIG_PASS} -lt 8 ]; then
    err "Password too short (min. 8 characters)."
fi

log "Password decoded (length: ${#CONFIG_PASS} characters)"

if [ "$CONFIG_C_MODE" != "sentinel-only" ] && [ "$CONFIG_C_MODE" != "full" ]; then
    err "CONFIG_C_MODE must be 'sentinel-only' or 'full', got: '${CONFIG_C_MODE}'"
fi

# Server C's role name if it turns out to be this host: reuses the "redis-replica" role
# wholesale when in "full" mode, so every later step (package install, redis.conf
# template, systemctl, verification) treats C exactly like B with no special-casing.
if [ "$CONFIG_C_MODE" = "full" ]; then
    C_ROLE="redis-replica"
    C_ROLE_LABEL="Redis replica + Sentinel"
else
    C_ROLE="sentinel-only"
    C_ROLE_LABEL="Sentinel only / arbiter"
fi

# -------------------------------------------------------------------
# Auto-detect server role by IP address
# -------------------------------------------------------------------
MY_IPS=$(hostname -I 2>/dev/null || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

ROLE="unknown"
MY_ROLE_IP=""
for ip in $MY_IPS; do
    if [ "$ip" = "$CONFIG_IP_A" ]; then ROLE="redis-master"; MY_ROLE_IP="$ip"; break; fi
    if [ "$ip" = "$CONFIG_IP_B" ]; then ROLE="redis-replica"; MY_ROLE_IP="$ip"; break; fi
    if [ "$ip" = "$CONFIG_IP_C" ]; then ROLE="$C_ROLE"; MY_ROLE_IP="$ip"; break; fi
done

if [ "$ROLE" = "unknown" ]; then
    warn "Could not detect role from IP address. Available IPs: $MY_IPS"
    echo ""
    echo "  Choose a role:"
    echo "  1) Server A — Redis master + Sentinel  (${CONFIG_IP_A})"
    echo "  2) Server B — Redis replica + Sentinel (${CONFIG_IP_B})"
    echo "  3) Server C — ${C_ROLE_LABEL}   (${CONFIG_IP_C})"
    read -rp "  Choice [1-3]: " choice
    case "$choice" in
        1) ROLE="redis-master"; MY_ROLE_IP="$CONFIG_IP_A" ;;
        2) ROLE="redis-replica"; MY_ROLE_IP="$CONFIG_IP_B" ;;
        3) ROLE="$C_ROLE"; MY_ROLE_IP="$CONFIG_IP_C" ;;
        *) err "Invalid choice." ;;
    esac
fi

log "Detected role: ${ROLE}"
log "Cluster: ${CONFIG_CLUSTER_NAME}"
log "Master:  ${CONFIG_IP_A}:6379"
echo ""

# -------------------------------------------------------------------
# Package installation
# -------------------------------------------------------------------
log "Installing Redis packages..."

# Check whether this is Ubuntu/Debian
if [ -f /etc/debian_version ]; then
    REDIS_SERVICE="redis-server"

    # Add the official Redis repository (packages.redis.io) — the only source that guarantees the latest version
    if ! dpkg -l | grep -q redis-tools; then
        DEBIAN_FRONTEND=noninteractive apt install -y -qq lsb-release curl gpg
        curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
        chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/redis.list
        apt update -qq
    fi

    # NOTE: the redis-sentinel package is just a symlink /usr/bin/redis-sentinel -> redis-server —
    # without the redis-server package that symlink is dangling and systemd fails to start the
    # service (exit 203/EXEC). That's why we always install both packages, even on the arbiter
    # (and just stop redis-server there).
    DEBIAN_FRONTEND=noninteractive apt install -y -qq redis redis-sentinel
    if [ "$ROLE" = "sentinel-only" ]; then
        systemctl stop "$REDIS_SERVICE" 2>/dev/null || true
        systemctl disable "$REDIS_SERVICE" 2>/dev/null || true
    fi
elif [ -f /etc/redhat-release ]; then
    # RHEL/Rocky/AlmaLinux
    REDIS_SERVICE="redis"
    RHEL_MAJOR=$(rpm -E %{rhel})
    if [ "$RHEL_MAJOR" != "8" ] && [ "$RHEL_MAJOR" != "9" ]; then
        err "Unsupported RHEL/Rocky/Alma version: ${RHEL_MAJOR}. Supported: 8, 9."
    fi

    # Add the official Redis repository (packages.redis.io) — without this, dnf pulls in
    # an outdated or nonexistent package from the distro's default repos
    if [ ! -f /etc/yum.repos.d/redis.repo ]; then
        cat > /etc/yum.repos.d/redis.repo << REPOEOF
[Redis]
name=Redis
baseurl=http://packages.redis.io/rpm/rockylinux${RHEL_MAJOR}
enabled=1
gpgcheck=1
REPOEOF
        curl -fsSL https://packages.redis.io/gpg > /tmp/redis.key
        rpm --import /tmp/redis.key
    fi

    dnf install -y redis
    # redis-sentinel is sometimes a separate package and sometimes bundled into "redis" depending
    # on the version — try it, but don't abort if it's not available
    dnf install -y redis-sentinel 2>/dev/null || true

    if [ "$ROLE" = "sentinel-only" ]; then
        systemctl stop "$REDIS_SERVICE" 2>/dev/null || true
        systemctl disable "$REDIS_SERVICE" 2>/dev/null || true
    fi
else
    err "Unsupported distribution. Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma."
fi

log "Packages installed."

# -------------------------------------------------------------------
# Kernel tuning — required/recommended by Redis (THP, overcommit, somaxconn)
# -------------------------------------------------------------------
log "Tuning kernel parameters..."

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi
cat > /etc/systemd/system/disable-thp.service << THPEOF
[Unit]
Description=Disable Transparent Huge Pages (required by Redis)
Before=redis-server.service redis.service redis-sentinel.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'

[Install]
WantedBy=multi-user.target
THPEOF
systemctl daemon-reload
systemctl enable --now disable-thp.service >/dev/null 2>&1 || true

cat > /etc/sysctl.d/99-redis.conf << SYSCTLEOF
# Required by Redis for fork() (BGSAVE / full replica resync)
vm.overcommit_memory = 1
# Queue of connections waiting for accept() — must be >= tcp-backlog in redis.conf
net.core.somaxconn = 511
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-redis.conf >/dev/null

log "Kernel tuning applied (THP disabled, overcommit_memory=1, somaxconn=511)."

# -------------------------------------------------------------------
# Redis configuration (Server A and B only)
# -------------------------------------------------------------------
if [ "$ROLE" != "sentinel-only" ]; then

    log "Configuring Redis (${ROLE})..."

    cat > /etc/redis/redis.conf << REDISEOF
# ═══════════════════════════════════════════════
# Redis HA — automatic configuration
# Role: ${ROLE}
# ═══════════════════════════════════════════════

bind ${MY_ROLE_IP} 127.0.0.1
protected-mode yes
port 6379
daemonize no
supervised systemd
loglevel notice
logfile /var/log/redis/redis.log
dir /var/lib/redis

# ═══ Redis IN-MEMORY ONLY — no disk writes ═══
save ""
appendonly no

# ═══ Password ═══
requirepass "${CONFIG_PASS}"
masterauth "${CONFIG_PASS}"

# ═══ Memory limit ═══
maxmemory ${CONFIG_MAXMEMORY}
maxmemory-policy allkeys-lru

# ═══ Network / performance ═══
tcp-keepalive 300
tcp-backlog 511

# ═══ Disabled dangerous commands ═══
rename-command FLUSHALL ""
rename-command FLUSHDB ""

# ═══ Replication ═══
REDISEOF

    if [ "$ROLE" = "redis-replica" ]; then
        cat >> /etc/redis/redis.conf << REDISEOF
# This server is a replica — replicates from Server A
replicaof ${CONFIG_IP_A} 6379
replica-read-only yes
REDISEOF
    fi

    systemctl restart "$REDIS_SERVICE"
    systemctl enable "$REDIS_SERVICE"
    log "Redis configured and started."
else
    log "Skipping Redis (arbiter — Sentinel only)."
fi

# -------------------------------------------------------------------
# Sentinel configuration (all 3 servers)
# -------------------------------------------------------------------
log "Configuring Sentinel..."

cat > /etc/redis/sentinel.conf << SENTINELEOF
# ═══════════════════════════════════════════════
# Redis Sentinel — automatic configuration
# Cluster: ${CONFIG_CLUSTER_NAME}
# ═══════════════════════════════════════════════

bind ${MY_ROLE_IP} 127.0.0.1
# NOTE: do NOT set protected-mode yes here — Sentinel has no requirepass, so
# unlike redis-server it does NOT get exempted from protected-mode by an
# explicit "bind". With protected-mode yes it blocks Sentinels from talking to
# each other (Sentinels stop seeing each other over the network → no
# failover). Port 26379 is secured by bind + the firewall rules below instead.
port 26379
daemonize no
supervised systemd
logfile /var/log/redis/sentinel.log
dir /var/lib/redis

# Monitor the master (quorum = 2)
sentinel monitor ${CONFIG_CLUSTER_NAME} ${CONFIG_IP_A} 6379 2
sentinel auth-pass ${CONFIG_CLUSTER_NAME} "${CONFIG_PASS}"

# Timeouts
sentinel down-after-milliseconds ${CONFIG_CLUSTER_NAME} 5000
sentinel failover-timeout ${CONFIG_CLUSTER_NAME} 15000
sentinel parallel-syncs ${CONFIG_CLUSTER_NAME} 1

# Security
sentinel resolve-hostnames no
sentinel announce-hostnames no
SENTINELEOF

systemctl restart redis-sentinel
systemctl enable redis-sentinel
log "Sentinel configured and started."

# -------------------------------------------------------------------
# Firewall (optional — only if ufw or firewalld is available)
# -------------------------------------------------------------------
# Peer IPs = the other two cluster members (topology-agnostic: works whether C is
# sentinel-only or a full Redis node — every node just opens up to its two peers).
PEER_IPS=""
for peer_ip in "$CONFIG_IP_A" "$CONFIG_IP_B" "$CONFIG_IP_C"; do
    [ "$peer_ip" = "$MY_ROLE_IP" ] && continue
    PEER_IPS="$PEER_IPS $peer_ip"
done

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "Configuring firewall (ufw)..."
    for peer_ip in $PEER_IPS; do
        if [ "$ROLE" != "sentinel-only" ]; then
            ufw allow from "$peer_ip" to any port 6379 proto tcp 2>/dev/null || true
        fi
        ufw allow from "$peer_ip" to any port 26379 proto tcp 2>/dev/null || true
    done
    log "Firewall configured."
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    log "Configuring firewall (firewalld)..."
    for peer_ip in $PEER_IPS; do
        if [ "$ROLE" != "sentinel-only" ]; then
            firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${peer_ip} port port=6379 protocol=tcp accept" 2>/dev/null || true
        fi
        firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${peer_ip} port port=26379 protocol=tcp accept" 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    log "Firewall (firewalld) configured."
else
    warn "No active firewall detected (ufw/firewalld) — ports 6379/26379 are reachable from any host with network access to this machine. Configure a firewall or cloud security group manually."
fi

# -------------------------------------------------------------------
# Verification
# -------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Installation finished — role: ${ROLE}"
echo "═══════════════════════════════════════════════════════"
echo ""

if [ "$ROLE" != "sentinel-only" ]; then
    echo ">>> Redis INFO replication:"
    if [ "$ROLE" = "redis-replica" ]; then
        # A full resync with the master (RDB transfer) takes a moment — don't check
        # immediately, master_link_status can show "down" for a second or two even
        # though replication is working correctly.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if redis-cli --no-auth-warning -a "${CONFIG_PASS}" INFO replication 2>/dev/null | grep -q "master_link_status:up"; then
                break
            fi
            sleep 1
        done
    fi
    redis-cli --no-auth-warning -a "${CONFIG_PASS}" INFO replication 2>/dev/null | \
        grep -E "role|master_host|master_link_status|connected_slaves" || warn "Redis is not responding — check the logs"
    echo ""
fi

echo ">>> Sentinel master:"
redis-cli -p 26379 SENTINEL master ${CONFIG_CLUSTER_NAME} 2>/dev/null | paste - - | \
    grep -E "^(ip|port|flags|num-slaves|num-other-sentinels)	" || warn "Sentinel is not responding — check the logs"

echo ""
echo ">>> Other Sentinels:"
SENTINEL_COUNT=$(redis-cli -p 26379 SENTINEL sentinels ${CONFIG_CLUSTER_NAME} 2>/dev/null | grep -c "^name$" || true)
echo "${SENTINEL_COUNT:-0}"

echo ""
log "Done! Run this script on the remaining servers."
log "Once installed on all 3 servers, verify the cluster:"
echo "  redis-cli -h ${CONFIG_IP_A} -p 26379 SENTINEL sentinels ${CONFIG_CLUSTER_NAME} | grep -c name"
echo "  # Should return: 2  (the two other Sentinels)"
echo ""

# Configuration summary to paste into Kamailio
echo "═══════════════════════════════════════════════════════"
echo "  Kamailio — db_redis config:"
echo "═══════════════════════════════════════════════════════"
cat << KAMCONF
modparam("db_redis", "with_sentinels", 1)
modparam("db_redis", "sentinels_config",
    "${CONFIG_IP_A}:26379,${CONFIG_IP_B}:26379,${CONFIG_IP_C}:26379")
modparam("db_redis", "redis_master_name", "${CONFIG_CLUSTER_NAME}")
modparam("db_redis", "db_pass", "${CONFIG_PASS}")
KAMCONF

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Kamailio — ndb_redis config:"
echo "═══════════════════════════════════════════════════════"
cat << KAMCONF2
modparam("ndb_redis", "server",
    "name=redis_master;sentinel_group=${CONFIG_CLUSTER_NAME};sentinel_master=1;"
    "sentinel=${CONFIG_IP_A}:26379;sentinel=${CONFIG_IP_B}:26379;sentinel=${CONFIG_IP_C}:26379")
KAMCONF2

echo ""
echo ">>> IMPORTANT: Redis is running in IN-MEMORY ONLY mode (save '', appendonly no)."
echo "    Data will be lost when Redis restarts."
echo "    To change this, edit /etc/redis/redis.conf and remove 'save \"\"'."
