#!/usr/bin/env bash
#
# Install and validate oliver006/redis_exporter as systemd services.
# Supports a Redis+Sentinel node, Redis-only node, or Sentinel-only arbiter.
#
# Typical usage:
#   sudo bash install-redis-exporter.sh \
#     --mode auto \
#     --prometheus-source 10.20.30.40/32 \
#     --redis-password-file /root/redis-password
#
# Sentinel-only arbiter without Sentinel authentication:
#   sudo bash install-redis-exporter.sh \
#     --mode sentinel-only \
#     --prometheus-source 10.20.30.40/32
#

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly MIN_EXPORTER_VERSION="v1.80.2"

MODE="auto"
VERSION_REQUEST="latest"
REDIS_PORT="6379"
SENTINEL_PORT="26379"
REDIS_EXPORTER_PORT="9121"
SENTINEL_EXPORTER_PORT="9122"
LISTEN_ADDRESS="0.0.0.0"
ADVERTISE_ADDRESS=""
PROMETHEUS_SOURCE=""
CONFIGURE_FIREWALL=1
REPORT_FILE=""
REDIS_PASSWORD_FILE=""
SENTINEL_PASSWORD_FILE=""
REDIS_USERNAME="${REDIS_USER:-}"
SENTINEL_USERNAME="${SENTINEL_USER:-}"
REDIS_SECRET="${REDIS_PASSWORD:-}"
SENTINEL_SECRET="${SENTINEL_PASSWORD:-}"
SKIP_CHECKSUM=0
NON_INTERACTIVE=0

# Do not pass monitoring secrets to child processes by inheritance.
unset REDIS_USER SENTINEL_USER REDIS_PASSWORD SENTINEL_PASSWORD || true

declare -a PASSES=()
declare -a WARNINGS=()
declare -a FAILURES=()
declare -a NEXT_ACTIONS=()
declare -A BACKUP_EXISTS=()
declare -a MUTATED_PATHS=()

TEMP_DIR=""
BACKUP_DIR=""
TRANSACTION_STARTED=0
FINISHED=0
PREV_REDIS_ACTIVE=0
PREV_REDIS_ENABLED=0
PREV_SENTINEL_ACTIVE=0
PREV_SENTINEL_ENABLED=0
FIREWALL_RESULT="not configured"
DETECTED_MODE=""
EXPORTER_VERSION="unknown"
EXPORTER_ARCH="unknown"
EXPORTER_SHA256="unknown"
ARCHIVE_SHA256="unknown"
PROMETHEUS_SNIPPET="/etc/redis_exporter/prometheus-scrape.yml"

usage() {
    cat <<'USAGE'
Usage:
  sudo bash install-redis-exporter.sh [options]

Required unless --no-firewall is used:
  --prometheus-source IP[/CIDR]   Prometheus source allowed to ports 9121/9122

Node selection:
  --mode MODE                     auto|full|redis-only|sentinel-only (default: auto)
  --redis-port PORT               Local Redis port (default: 6379)
  --sentinel-port PORT            Local Sentinel port (default: 26379)

Authentication:
  --redis-user USER               Optional Redis ACL username
  --redis-password-file FILE      File containing the Redis password (first line)
  --sentinel-user USER            Optional Sentinel ACL username
  --sentinel-password-file FILE   File containing the Sentinel password (first line)

  If authentication is required and no password file/environment variable is
  supplied, the script asks securely on an interactive terminal. Environment
  variables REDIS_PASSWORD/SENTINEL_PASSWORD and REDIS_USER/SENTINEL_USER are
  also accepted, but a root-readable password file is recommended with sudo.

Exporter/network:
  --version VERSION               latest or a tag such as v1.88.0 (default: latest)
  --listen-address ADDRESS        Exporter bind address (default: 0.0.0.0)
  --advertise-address ADDRESS     Address written to the Prometheus snippet
  --redis-exporter-port PORT      Redis exporter port (default: 9121)
  --sentinel-exporter-port PORT   Sentinel exporter port (default: 9122)
  --no-firewall                   Do not change a running UFW/firewalld instance
  --skip-checksum                 Explicitly allow install when GitHub has no digest
  --non-interactive               Never prompt; fail if required input is missing
  --report FILE                   Report path (default: /var/log/...timestamp...txt)
  -h, --help                      Show this help

Examples:
  # Redis + Sentinel node:
  sudo bash install-redis-exporter.sh --mode full \
    --prometheus-source 10.20.30.40/32 \
    --redis-password-file /root/redis-password

  # Sentinel-only arbiter without authentication:
  sudo bash install-redis-exporter.sh --mode sentinel-only \
    --prometheus-source 10.20.30.40/32
USAGE
}

need_arg() {
    if (($# < 2)) || [[ -z "${2:-}" ]]; then
        printf 'ERROR: %s requires a value.\n' "$1" >&2
        exit 2
    fi
}

while (($#)); do
    case "$1" in
        --mode)
            need_arg "$@"; MODE="$2"; shift 2 ;;
        --version)
            need_arg "$@"; VERSION_REQUEST="$2"; shift 2 ;;
        --redis-port)
            need_arg "$@"; REDIS_PORT="$2"; shift 2 ;;
        --sentinel-port)
            need_arg "$@"; SENTINEL_PORT="$2"; shift 2 ;;
        --redis-exporter-port)
            need_arg "$@"; REDIS_EXPORTER_PORT="$2"; shift 2 ;;
        --sentinel-exporter-port)
            need_arg "$@"; SENTINEL_EXPORTER_PORT="$2"; shift 2 ;;
        --listen-address)
            need_arg "$@"; LISTEN_ADDRESS="$2"; shift 2 ;;
        --advertise-address)
            need_arg "$@"; ADVERTISE_ADDRESS="$2"; shift 2 ;;
        --prometheus-source)
            need_arg "$@"; PROMETHEUS_SOURCE="$2"; shift 2 ;;
        --redis-user)
            need_arg "$@"; REDIS_USERNAME="$2"; shift 2 ;;
        --sentinel-user)
            need_arg "$@"; SENTINEL_USERNAME="$2"; shift 2 ;;
        --redis-password-file)
            need_arg "$@"; REDIS_PASSWORD_FILE="$2"; shift 2 ;;
        --sentinel-password-file)
            need_arg "$@"; SENTINEL_PASSWORD_FILE="$2"; shift 2 ;;
        --report)
            need_arg "$@"; REPORT_FILE="$2"; shift 2 ;;
        --no-firewall)
            CONFIGURE_FIREWALL=0; shift ;;
        --skip-checksum)
            SKIP_CHECKSUM=1; shift ;;
        --non-interactive)
            NON_INTERACTIVE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            printf 'ERROR: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2 ;;
    esac
done

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*"
}

pass() {
    PASSES+=("$*")
    log "PASS: $*"
}

warn() {
    WARNINGS+=("$*")
    log "WARN: $*"
}

record_failure() {
    FAILURES+=("$*")
    log "FAIL: $*"
}

add_action() {
    NEXT_ACTIONS+=("$*")
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

service_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

restore_service_state() {
    local service="$1" was_active="$2" was_enabled="$3"

    if ((was_enabled)); then
        systemctl enable "$service" >/dev/null 2>&1 || true
    else
        systemctl disable "$service" >/dev/null 2>&1 || true
    fi

    if ((was_active)); then
        systemctl restart "$service" >/dev/null 2>&1 || true
    else
        systemctl stop "$service" >/dev/null 2>&1 || true
    fi
}

rollback() {
    local path backup
    ((TRANSACTION_STARTED)) || return 0

    log "Rolling back files and service state after installation failure."
    for path in "${MUTATED_PATHS[@]}"; do
        backup="${BACKUP_DIR}${path}"
        if [[ "${BACKUP_EXISTS[$path]:-0}" == "1" ]]; then
            [[ -d "$(dirname "$path")" ]] || mkdir -p -- "$(dirname "$path")" || true
            cp -a -- "$backup" "$path" || true
        else
            rm -f -- "$path" || true
        fi
    done

    systemctl daemon-reload >/dev/null 2>&1 || true
    restore_service_state redis_exporter.service "$PREV_REDIS_ACTIVE" "$PREV_REDIS_ENABLED"
    restore_service_state redis_exporter_sentinel.service "$PREV_SENTINEL_ACTIVE" "$PREV_SENTINEL_ENABLED"
    TRANSACTION_STARTED=0
    warn "Changes were rolled back; inspect the failures and system journal."
}

print_array() {
    local title="$1"
    shift
    local -a values=("$@")
    local item

    printf '\n%s (%d)\n' "$title" "${#values[@]}"
    if ((${#values[@]} == 0)); then
        printf '  - none\n'
        return
    fi
    for item in "${values[@]}"; do
        printf '  - %s\n' "$item"
    done
}

finish() {
    local rc="$1"
    ((FINISHED)) && exit "$rc"
    FINISHED=1
    trap - ERR

    if ((rc != 0)); then
        rollback
    fi

    printf '\n============================================================\n'
    printf 'REDIS EXPORTER INSTALLATION REPORT\n'
    printf '============================================================\n'
    printf 'Result:                 %s\n' "$([[ $rc -eq 0 ]] && printf SUCCESS || printf FAILED)"
    printf 'Finished (UTC):         %s\n' "$(timestamp)"
    printf 'Host:                   %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'Detected/selected mode: %s\n' "${DETECTED_MODE:-not reached}"
    printf 'Exporter version:       %s\n' "$EXPORTER_VERSION"
    printf 'Exporter architecture:  %s\n' "$EXPORTER_ARCH"
    printf 'Archive SHA-256:        %s\n' "$ARCHIVE_SHA256"
    printf 'Binary SHA-256:         %s\n' "$EXPORTER_SHA256"
    printf 'Redis endpoint:         redis://127.0.0.1:%s\n' "$REDIS_PORT"
    printf 'Sentinel endpoint:      redis://127.0.0.1:%s\n' "$SENTINEL_PORT"
    printf 'Redis exporter:         %s:%s\n' "$LISTEN_ADDRESS" "$REDIS_EXPORTER_PORT"
    printf 'Sentinel exporter:      %s:%s\n' "$LISTEN_ADDRESS" "$SENTINEL_EXPORTER_PORT"
    printf 'Prometheus target IP:   %s\n' "${ADVERTISE_ADDRESS:-unknown}"
    printf 'Prometheus source:      %s\n' "${PROMETHEUS_SOURCE:-not supplied}"
    printf 'Firewall:               %s\n' "$FIREWALL_RESULT"
    printf 'Redis authentication:   %s\n' "$([[ -n "$REDIS_SECRET" ]] && printf configured || printf 'not configured')"
    printf 'Sentinel authentication:%s\n' "$([[ -n "$SENTINEL_SECRET" ]] && printf ' configured' || printf ' not configured')"
    printf 'Prometheus snippet:     %s\n' "$PROMETHEUS_SNIPPET"
    printf 'Report file:            %s\n' "$REPORT_FILE"

    print_array "PASSED CHECKS" "${PASSES[@]}"
    print_array "WARNINGS" "${WARNINGS[@]}"
    print_array "FAILURES" "${FAILURES[@]}"
    print_array "NEXT ACTIONS" "${NEXT_ACTIONS[@]}"
    printf '============================================================\n'

    exit "$rc"
}

die() {
    record_failure "$*"
    finish 1
}

on_unexpected_error() {
    local line="$1" rc="$2"
    record_failure "Unexpected error at script line ${line} (exit code ${rc})."
    finish "$rc"
}

trap 'on_unexpected_error "$LINENO" "$?"' ERR
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
    printf 'ERROR: run this installer as root (for example with sudo).\n' >&2
    exit 1
fi

case "$MODE" in
    auto|full|redis-only|sentinel-only) ;;
    *) printf 'ERROR: invalid --mode: %s\n' "$MODE" >&2; exit 2 ;;
esac

validate_port() {
    local label="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$label is not a number: $value"
    ((value >= 1 && value <= 65535)) || die "$label is outside 1-65535: $value"
}

validate_port "Redis port" "$REDIS_PORT"
validate_port "Sentinel port" "$SENTINEL_PORT"
validate_port "Redis exporter port" "$REDIS_EXPORTER_PORT"
validate_port "Sentinel exporter port" "$SENTINEL_EXPORTER_PORT"
[[ "$REDIS_EXPORTER_PORT" != "$SENTINEL_EXPORTER_PORT" ]] || \
    die "Redis and Sentinel exporter ports must be different."

if [[ ! "$LISTEN_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    die "--listen-address must be an IPv4 or IPv6 address without a port."
fi
if [[ -n "$ADVERTISE_ADDRESS" && ! "$ADVERTISE_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    die "--advertise-address must be an IPv4 or IPv6 address without a port."
fi
if ((CONFIGURE_FIREWALL)); then
    [[ -n "$PROMETHEUS_SOURCE" ]] || \
        die "--prometheus-source is required unless --no-firewall is used."
    if [[ ! "$PROMETHEUS_SOURCE" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
        die "--prometheus-source must be an IPv4/IPv6 address or CIDR."
    fi
fi
if [[ "$VERSION_REQUEST" != "latest" && ! "$VERSION_REQUEST" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    die "Invalid exporter version/tag: $VERSION_REQUEST"
fi

if [[ -z "$REPORT_FILE" ]]; then
    REPORT_FILE="/var/log/redis-exporter-install-report-$(date -u '+%Y%m%d-%H%M%S').txt"
fi
install -d -m 0750 "$(dirname "$REPORT_FILE")"
install -m 0600 /dev/null "$REPORT_FILE"
exec > >(tee -a "$REPORT_FILE") 2>&1

printf 'redis_exporter installation started at %s\n' "$(timestamp)"
printf 'Script: %s\n' "$SCRIPT_NAME"

install_dependencies() {
    local -a required=(curl tar sha256sum useradd getent ss systemctl python3)
    local -a missing=()
    local command_name

    for command_name in "${required[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]} == 0)); then
        pass "Required operating-system tools are installed."
        return
    fi

    log "Installing prerequisites; missing commands: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            ca-certificates curl tar coreutils iproute2 passwd python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar coreutils iproute shadow-utils python3
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar coreutils iproute shadow-utils python3
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install ca-certificates curl tar coreutils iproute2 shadow python3
    else
        die "Cannot install prerequisites: supported package manager not found. Missing: ${missing[*]}"
    fi

    for command_name in "${required[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "Required command is still missing after package installation: $command_name"
    done
    pass "Required operating-system tools were installed."
}

install_dependencies
[[ -d /run/systemd/system ]] || die "systemd is not PID 1 or its runtime directory is unavailable."
pass "systemd is available."

TEMP_DIR="$(mktemp -d /tmp/redis-exporter-install.XXXXXX)"
BACKUP_DIR="$TEMP_DIR/backup"
install -d -m 0700 "$BACKUP_DIR"

port_is_listening() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v suffix=":${port}" '
        $4 ~ (suffix "$" ) { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

unit_is_enabled_or_active() {
    local unit
    for unit in "$@"; do
        systemctl is-enabled --quiet "$unit" 2>/dev/null && return 0
        systemctl is-active --quiet "$unit" 2>/dev/null && return 0
    done
    return 1
}

redis_listening=0
sentinel_listening=0
port_is_listening "$REDIS_PORT" && redis_listening=1
port_is_listening "$SENTINEL_PORT" && sentinel_listening=1

if [[ "$MODE" == "auto" ]]; then
    if ((redis_listening && sentinel_listening)); then
        DETECTED_MODE="full"
    elif ((redis_listening)); then
        DETECTED_MODE="redis-only"
    elif ((sentinel_listening)); then
        if unit_is_enabled_or_active redis-server.service redis.service; then
            die "Redis port ${REDIS_PORT} is closed, but a Redis service is active/enabled. Fix Redis or select --mode sentinel-only explicitly."
        fi
        DETECTED_MODE="sentinel-only"
    else
        die "Neither Redis (${REDIS_PORT}) nor Sentinel (${SENTINEL_PORT}) is listening locally."
    fi
else
    DETECTED_MODE="$MODE"
fi

case "$DETECTED_MODE" in
    full)
        ((redis_listening)) || die "Mode full requires local Redis on port ${REDIS_PORT}."
        ((sentinel_listening)) || die "Mode full requires local Sentinel on port ${SENTINEL_PORT}."
        ;;
    redis-only)
        ((redis_listening)) || die "Mode redis-only requires local Redis on port ${REDIS_PORT}."
        ;;
    sentinel-only)
        ((sentinel_listening)) || die "Mode sentinel-only requires local Sentinel on port ${SENTINEL_PORT}."
        ;;
esac
pass "Local service detection selected mode: $DETECTED_MODE."

check_exporter_port_conflict() {
    local port="$1" expected_service="$2"
    local listeners
    if port_is_listening "$port"; then
        listeners="$(ss -H -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ (suffix "$")')"
        if [[ "$listeners" != *redis_exporter* ]] || ! service_is_active "$expected_service"; then
            printf '%s\n' "$listeners"
            die "TCP port ${port} is already in use and is not owned by active ${expected_service}."
        fi
    fi
}

case "$DETECTED_MODE" in
    full)
        check_exporter_port_conflict "$REDIS_EXPORTER_PORT" redis_exporter.service
        check_exporter_port_conflict "$SENTINEL_EXPORTER_PORT" redis_exporter_sentinel.service
        ;;
    redis-only)
        check_exporter_port_conflict "$REDIS_EXPORTER_PORT" redis_exporter.service
        ;;
    sentinel-only)
        check_exporter_port_conflict "$SENTINEL_EXPORTER_PORT" redis_exporter_sentinel.service
        ;;
esac
pass "Required exporter TCP port(s) are available or owned by the existing exporter service(s)."

read_secret_file() {
    local label="$1" file="$2" variable_name="$3"
    local value
    [[ -f "$file" && -r "$file" ]] || die "$label password file is not readable: $file"
    value="$(<"$file")"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
        die "$label password file must contain one line only."
    printf -v "$variable_name" '%s' "$value"
}

[[ -z "$REDIS_PASSWORD_FILE" ]] || read_secret_file "Redis" "$REDIS_PASSWORD_FILE" REDIS_SECRET
[[ -z "$SENTINEL_PASSWORD_FILE" ]] || read_secret_file "Sentinel" "$SENTINEL_PASSWORD_FILE" SENTINEL_SECRET

redis_cli_ping() {
    local port="$1" user="$2" secret="$3" output_variable="$4"
    # Do not name this local variable "output": the caller deliberately passes
    # its own local variable named "output". Bash uses dynamic scoping, so a
    # same-named local here would make printf -v update this function's copy
    # instead of returning the Redis response to validate_local_auth().
    local captured_output rc
    local -a args=(-h 127.0.0.1 -p "$port" --no-auth-warning)
    [[ -z "$user" ]] || args+=(--user "$user")

    set +e
    captured_output="$({
        if [[ -n "$secret" ]]; then
            export REDISCLI_AUTH="$secret"
        else
            unset REDISCLI_AUTH || true
        fi
        timeout 5 redis-cli "${args[@]}" PING
    } 2>&1)"
    rc=$?
    set -e
    printf -v "$output_variable" '%s' "$captured_output"
    return "$rc"
}

prompt_for_secret() {
    local label="$1" variable_name="$2" value
    if ((NON_INTERACTIVE)) || [[ ! -t 0 ]]; then
        die "$label requires authentication; supply --${label,,}-password-file in non-interactive mode."
    fi
    read -r -s -p "${label} password: " value
    printf '\n'
    [[ -n "$value" ]] || die "$label password cannot be empty when authentication is required."
    printf -v "$variable_name" '%s' "$value"
}

validate_local_auth() {
    local label="$1" port="$2" user="$3" secret_variable="$4"
    local output=""
    local secret="${!secret_variable}"

    if ! command -v redis-cli >/dev/null 2>&1; then
        warn "redis-cli is unavailable; $label authentication will be validated through exporter metrics."
        return
    fi

    if redis_cli_ping "$port" "$user" "$secret" output && [[ "$output" == *PONG* ]]; then
        pass "$label answered PING."
        return
    fi

    if [[ -z "$secret" && "$output" == *NOAUTH* ]]; then
        prompt_for_secret "$label" "$secret_variable"
        secret="${!secret_variable}"
        if redis_cli_ping "$port" "$user" "$secret" output && [[ "$output" == *PONG* ]]; then
            pass "$label authentication and PING succeeded."
            return
        fi
    fi

    die "$label PING/authentication failed: ${output:-no response}"
}

case "$DETECTED_MODE" in
    full)
        validate_local_auth Redis "$REDIS_PORT" "$REDIS_USERNAME" REDIS_SECRET
        validate_local_auth Sentinel "$SENTINEL_PORT" "$SENTINEL_USERNAME" SENTINEL_SECRET
        ;;
    redis-only)
        validate_local_auth Redis "$REDIS_PORT" "$REDIS_USERNAME" REDIS_SECRET
        ;;
    sentinel-only)
        validate_local_auth Sentinel "$SENTINEL_PORT" "$SENTINEL_USERNAME" SENTINEL_SECRET
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64) EXPORTER_ARCH="amd64" ;;
    aarch64|arm64) EXPORTER_ARCH="arm64" ;;
    armv7l|armv7*) EXPORTER_ARCH="arm" ;;
    *) die "Unsupported machine architecture: $(uname -m)" ;;
esac

release_api="https://api.github.com/repos/oliver006/redis_exporter/releases"
if [[ "$VERSION_REQUEST" == "latest" ]]; then
    release_api+="/latest"
else
    [[ "$VERSION_REQUEST" == v* ]] || VERSION_REQUEST="v${VERSION_REQUEST}"
    release_api+="/tags/${VERSION_REQUEST}"
fi

release_json="$TEMP_DIR/release.json"
log "Resolving redis_exporter release metadata from GitHub."
curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H "User-Agent: ${SCRIPT_NAME}" \
    -o "$release_json" "$release_api" || \
    die "Could not download GitHub release metadata (API rate limit or network problem)."

release_parse_error="$TEMP_DIR/release-parse.error"
if ! EXPORTER_VERSION="$(python3 - "$release_json" 2>"$release_parse_error" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid JSON: {exc}")

tag = payload.get("tag_name") if isinstance(payload, dict) else None
if not isinstance(tag, str) or not tag.strip():
    message = payload.get("message") if isinstance(payload, dict) else None
    detail = f"; GitHub message: {message}" if message else ""
    raise SystemExit(f"tag_name is missing or empty{detail}")

print(tag.strip())
PY
)"; then
    parse_detail="$(tr '\n' ' ' <"$release_parse_error" | cut -c1-300)"
    die "Could not parse tag_name from GitHub release metadata: ${parse_detail:-unknown JSON error}."
fi

version_ge() {
    local current="${1#v}" minimum="${2#v}"
    [[ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
}
version_ge "$EXPORTER_VERSION" "$MIN_EXPORTER_VERSION" || \
    die "Exporter ${EXPORTER_VERSION} is too old for the required Sentinel metrics; minimum is ${MIN_EXPORTER_VERSION}."

asset_name="redis_exporter-${EXPORTER_VERSION}.linux-${EXPORTER_ARCH}.tar.gz"
asset_url="https://github.com/oliver006/redis_exporter/releases/download/${EXPORTER_VERSION}/${asset_name}"
expected_sha256="$(python3 - "$release_json" "$asset_name" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

target = sys.argv[2]
for asset in payload.get("assets", []):
    if asset.get("name") != target:
        continue
    digest = asset.get("digest")
    if isinstance(digest, str) and digest.startswith("sha256:"):
        print(digest.removeprefix("sha256:"))
    break
PY
)"

archive="$TEMP_DIR/$asset_name"
log "Downloading ${asset_name}."
curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --tlsv1.2 \
    -o "$archive" "$asset_url" || die "Failed to download ${asset_url}."

ARCHIVE_SHA256="$(sha256sum "$archive" | awk '{print $1}')"
if [[ -n "$expected_sha256" && "$expected_sha256" != "null" ]]; then
    [[ "$ARCHIVE_SHA256" == "$expected_sha256" ]] || \
        die "SHA-256 mismatch for ${asset_name}: expected ${expected_sha256}, got ${ARCHIVE_SHA256}."
    pass "Downloaded archive SHA-256 matches GitHub release metadata."
elif ((SKIP_CHECKSUM)); then
    warn "GitHub did not publish a digest for ${asset_name}; checksum verification was explicitly skipped."
else
    die "GitHub release metadata has no SHA-256 digest for ${asset_name}; use --skip-checksum only after manual verification."
fi

archive_list="$TEMP_DIR/archive.list"
tar -tzf "$archive" >"$archive_list" || die "Downloaded archive is not a valid gzip-compressed tar file."
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$archive_list"; then
    die "Archive contains an unsafe absolute or parent-relative path."
fi
extract_dir="$TEMP_DIR/extracted"
install -d -m 0700 "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
binary_source="$(find "$extract_dir" -type f -name redis_exporter -print -quit)"
[[ -n "$binary_source" ]] || die "redis_exporter binary was not found in the release archive."
chmod 0755 "$binary_source"
EXPORTER_SHA256="$(sha256sum "$binary_source" | awk '{print $1}')"
"$binary_source" --version
pass "Downloaded redis_exporter binary executes successfully."

if ! getent passwd redis_exporter >/dev/null; then
    nologin_shell="$(command -v nologin 2>/dev/null || true)"
    [[ -n "$nologin_shell" ]] || nologin_shell="/usr/sbin/nologin"
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell "$nologin_shell" redis_exporter
    pass "Created system user redis_exporter."
else
    pass "System user redis_exporter already exists."
fi

PREV_REDIS_ACTIVE=0; service_is_active redis_exporter.service && PREV_REDIS_ACTIVE=1
PREV_REDIS_ENABLED=0; service_is_enabled redis_exporter.service && PREV_REDIS_ENABLED=1
PREV_SENTINEL_ACTIVE=0; service_is_active redis_exporter_sentinel.service && PREV_SENTINEL_ACTIVE=1
PREV_SENTINEL_ENABLED=0; service_is_enabled redis_exporter_sentinel.service && PREV_SENTINEL_ENABLED=1

backup_path() {
    local path="$1" backup="${BACKUP_DIR}${1}"
    MUTATED_PATHS+=("$path")
    if [[ -e "$path" || -L "$path" ]]; then
        BACKUP_EXISTS["$path"]=1
        install -d -m 0700 "$(dirname "$backup")"
        cp -a -- "$path" "$backup"
    else
        BACKUP_EXISTS["$path"]=0
    fi
}

readonly BINARY_PATH="/usr/local/bin/redis_exporter"
readonly CONFIG_DIR="/etc/redis_exporter"
readonly REDIS_ENV="$CONFIG_DIR/redis.env"
readonly SENTINEL_ENV="$CONFIG_DIR/sentinel.env"
readonly REDIS_UNIT="/etc/systemd/system/redis_exporter.service"
readonly SENTINEL_UNIT="/etc/systemd/system/redis_exporter_sentinel.service"

for managed_path in \
    "$BINARY_PATH" "$REDIS_ENV" "$SENTINEL_ENV" \
    "$REDIS_UNIT" "$SENTINEL_UNIT" "$PROMETHEUS_SNIPPET"; do
    backup_path "$managed_path"
done
TRANSACTION_STARTED=1

install -o root -g root -m 0755 "$binary_source" "$BINARY_PATH"
install -d -o root -g redis_exporter -m 0750 "$CONFIG_DIR"
pass "Installed ${BINARY_PATH} (${EXPORTER_VERSION})."

systemd_quote() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
        die "A systemd environment value contains a newline."
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_env_file() {
    local file="$1" addr="$2" web_address="$3" user="$4" secret="$5"
    local temporary="${file}.new"

    {
        printf 'REDIS_ADDR=%s\n' "$(systemd_quote "$addr")"
        printf 'REDIS_EXPORTER_WEB_LISTEN_ADDRESS=%s\n' "$(systemd_quote "$web_address")"
        printf 'REDIS_EXPORTER_CONNECTION_TIMEOUT=%s\n' "$(systemd_quote '5s')"
        printf 'REDIS_EXPORTER_PING_ON_CONNECT=%s\n' "$(systemd_quote 'true')"
        if version_ge "$EXPORTER_VERSION" "v1.82.0"; then
            printf 'REDIS_EXPORTER_APPEND_INSTANCE_ROLE_LABEL=%s\n' "$(systemd_quote 'true')"
        fi
        if version_ge "$EXPORTER_VERSION" "v1.83.0"; then
            printf 'REDIS_EXPORTER_DISABLE_SCRAPE_ENDPOINT=%s\n' "$(systemd_quote 'true')"
        fi
        [[ -z "$user" ]] || printf 'REDIS_USER=%s\n' "$(systemd_quote "$user")"
        [[ -z "$secret" ]] || printf 'REDIS_PASSWORD=%s\n' "$(systemd_quote "$secret")"
    } >"$temporary"
    chown root:redis_exporter "$temporary"
    chmod 0640 "$temporary"
    mv -f -- "$temporary" "$file"
}

format_listen_address() {
    local address="$1" port="$2"
    if [[ "$address" == *:* ]]; then
        printf '[%s]:%s' "$address" "$port"
    else
        printf '%s:%s' "$address" "$port"
    fi
}

if [[ "$DETECTED_MODE" == "full" || "$DETECTED_MODE" == "redis-only" ]]; then
    write_env_file "$REDIS_ENV" "redis://127.0.0.1:${REDIS_PORT}" \
        "$(format_listen_address "$LISTEN_ADDRESS" "$REDIS_EXPORTER_PORT")" \
        "$REDIS_USERNAME" "$REDIS_SECRET"
fi
if [[ "$DETECTED_MODE" == "full" || "$DETECTED_MODE" == "sentinel-only" ]]; then
    write_env_file "$SENTINEL_ENV" "redis://127.0.0.1:${SENTINEL_PORT}" \
        "$(format_listen_address "$LISTEN_ADDRESS" "$SENTINEL_EXPORTER_PORT")" \
        "$SENTINEL_USERNAME" "$SENTINEL_SECRET"
fi

cat >"$REDIS_UNIT" <<'UNIT'
[Unit]
Description=Prometheus Redis Exporter
Documentation=https://github.com/oliver006/redis_exporter
Wants=network-online.target
After=network-online.target redis-server.service redis.service

[Service]
Type=simple
User=redis_exporter
Group=redis_exporter
EnvironmentFile=/etc/redis_exporter/redis.env
ExecStart=/usr/local/bin/redis_exporter
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
UMask=0077

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectClock=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectHostname=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
UNIT

cat >"$SENTINEL_UNIT" <<'UNIT'
[Unit]
Description=Prometheus Redis Sentinel Exporter
Documentation=https://github.com/oliver006/redis_exporter
Wants=network-online.target
After=network-online.target redis-sentinel.service

[Service]
Type=simple
User=redis_exporter
Group=redis_exporter
EnvironmentFile=/etc/redis_exporter/sentinel.env
ExecStart=/usr/local/bin/redis_exporter
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
UMask=0077

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectClock=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectHostname=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
UNIT

chmod 0644 "$REDIS_UNIT" "$SENTINEL_UNIT"

if command -v systemd-analyze >/dev/null 2>&1; then
    units_to_verify=()
    case "$DETECTED_MODE" in
        full) units_to_verify=("$REDIS_UNIT" "$SENTINEL_UNIT") ;;
        redis-only) units_to_verify=("$REDIS_UNIT") ;;
        sentinel-only) units_to_verify=("$SENTINEL_UNIT") ;;
    esac
    systemd-analyze verify "${units_to_verify[@]}" || \
        die "systemd-analyze rejected the generated service units."
    pass "Generated systemd units passed systemd-analyze verification."
else
    warn "systemd-analyze is unavailable; unit syntax was not independently verified."
fi

systemctl daemon-reload
case "$DETECTED_MODE" in
    full)
        systemctl enable redis_exporter.service redis_exporter_sentinel.service
        systemctl restart redis_exporter.service redis_exporter_sentinel.service
        ;;
    redis-only)
        systemctl enable redis_exporter.service
        systemctl restart redis_exporter.service
        systemctl disable --now redis_exporter_sentinel.service >/dev/null 2>&1 || true
        ;;
    sentinel-only)
        systemctl enable redis_exporter_sentinel.service
        systemctl restart redis_exporter_sentinel.service
        systemctl disable --now redis_exporter.service >/dev/null 2>&1 || true
        ;;
esac

local_test_address="$LISTEN_ADDRESS"
case "$LISTEN_ADDRESS" in
    0.0.0.0) local_test_address="127.0.0.1" ;;
    ::) local_test_address="::1" ;;
esac

metrics_url() {
    local address="$1" port="$2"
    if [[ "$address" == *:* ]]; then
        printf 'http://[%s]:%s/metrics' "$address" "$port"
    else
        printf 'http://%s:%s/metrics' "$address" "$port"
    fi
}

wait_for_metrics() {
    local url="$1" output="$2" attempt
    for attempt in {1..15}; do
        if curl --noproxy '*' --fail --silent --show-error --max-time 5 -o "$output" "$url"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

metrics_show_up() {
    awk '
        $1 ~ /^redis_up(\{[^}]*\})?$/ && ($2 + 0) == 1 { up=1 }
        END { exit(up ? 0 : 1) }
    ' "$1"
}

test_exporter_service() {
    local kind="$1" service="$2" port="$3" require_sentinel_metrics="$4"
    local output="$TEMP_DIR/${service}.metrics"
    local url
    url="$(metrics_url "$local_test_address" "$port")"

    service_is_active "$service" || {
        systemctl status "$service" --no-pager -l || true
        journalctl -u "$service" -n 50 --no-pager || true
        die "$service is not active after restart."
    }
    pass "$service is active."

    wait_for_metrics "$url" "$output" || {
        journalctl -u "$service" -n 50 --no-pager || true
        die "$kind metrics endpoint did not answer successfully: $url"
    }
    metrics_show_up "$output" || {
        tail -n 50 "$output" || true
        die "$kind exporter answered, but redis_up is not 1."
    }
    pass "$kind exporter metrics endpoint reports redis_up=1."

    if [[ "$require_sentinel_metrics" == "1" ]]; then
        grep -q '^redis_sentinel_' "$output" || \
            die "Sentinel exporter has no redis_sentinel_* metrics. Check Sentinel master configuration and exporter compatibility."
        pass "Sentinel-specific redis_sentinel_* metrics are present."
    fi
}

case "$DETECTED_MODE" in
    full)
        test_exporter_service Redis redis_exporter.service "$REDIS_EXPORTER_PORT" 0
        test_exporter_service Sentinel redis_exporter_sentinel.service "$SENTINEL_EXPORTER_PORT" 1
        ;;
    redis-only)
        test_exporter_service Redis redis_exporter.service "$REDIS_EXPORTER_PORT" 0
        ;;
    sentinel-only)
        test_exporter_service Sentinel redis_exporter_sentinel.service "$SENTINEL_EXPORTER_PORT" 1
        ;;
esac

infer_advertise_address() {
    local candidate="" route_target="${PROMETHEUS_SOURCE%/*}"

    if [[ -n "$route_target" && "$route_target" != *:* ]]; then
        candidate="$(ip route get "$route_target" 2>/dev/null | awk '
            { for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }
        ')"
    elif [[ -n "$route_target" && "$route_target" == *:* ]]; then
        candidate="$(ip -6 route get "$route_target" 2>/dev/null | awk '
            { for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }
        ')"
    fi
    if [[ -z "$candidate" ]]; then
        candidate="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "$candidate"
}

if [[ -z "$ADVERTISE_ADDRESS" ]]; then
    ADVERTISE_ADDRESS="$(infer_advertise_address)"
    if [[ -n "$ADVERTISE_ADDRESS" ]]; then
        warn "Prometheus target address was inferred as ${ADVERTISE_ADDRESS}; verify it in the generated snippet."
    else
        ADVERTISE_ADDRESS="NODE_IP"
        warn "Could not infer a Prometheus target address; replace NODE_IP in the generated snippet."
    fi
fi

configure_firewall() {
    local -a ports=()
    local port family zone rule
    case "$DETECTED_MODE" in
        full) ports=("$REDIS_EXPORTER_PORT" "$SENTINEL_EXPORTER_PORT") ;;
        redis-only) ports=("$REDIS_EXPORTER_PORT") ;;
        sentinel-only) ports=("$SENTINEL_EXPORTER_PORT") ;;
    esac

    if ((CONFIGURE_FIREWALL == 0)); then
        FIREWALL_RESULT="skipped by --no-firewall"
        warn "Local firewall configuration was skipped."
        add_action "Allow Prometheus to reach the enabled exporter port(s): ${ports[*]}/tcp."
        return
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        for port in "${ports[@]}"; do
            if ! ufw allow proto tcp from "$PROMETHEUS_SOURCE" to any port "$port" \
                comment 'Prometheus redis_exporter'; then
                FIREWALL_RESULT="UFW rule creation failed or was only partially completed"
                warn "$FIREWALL_RESULT."
                add_action "Inspect UFW and allow source ${PROMETHEUS_SOURCE} to exporter port(s): ${ports[*]}/tcp."
                return
            fi
        done
        FIREWALL_RESULT="UFW allow rules added/verified for ${PROMETHEUS_SOURCE}"
        pass "$FIREWALL_RESULT."
        if ufw status verbose 2>/dev/null | grep -qi 'Default: allow (incoming)'; then
            warn "UFW has a permissive incoming default; the source-specific rules do not restrict other clients."
        fi
        add_action "Audit existing UFW rules for broader pre-existing allows on exporter port(s): ${ports[*]}/tcp."
        return
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        zone="$(firewall-cmd --get-default-zone)"
        family="ipv4"; [[ "$PROMETHEUS_SOURCE" == *:* ]] && family="ipv6"
        for port in "${ports[@]}"; do
            rule="rule family=${family} source address=${PROMETHEUS_SOURCE} port port=${port} protocol=tcp accept"
            if ! firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 && \
               ! firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"; then
                FIREWALL_RESULT="firewalld rule creation failed or was only partially completed"
                warn "$FIREWALL_RESULT."
                add_action "Inspect firewalld and allow source ${PROMETHEUS_SOURCE} to exporter port(s): ${ports[*]}/tcp."
                return
            fi
        done
        if ! firewall-cmd --reload; then
            FIREWALL_RESULT="firewalld permanent rules were written, but reload failed"
            warn "$FIREWALL_RESULT."
            add_action "Reload firewalld after checking its status."
            return
        fi
        FIREWALL_RESULT="firewalld rich rules added/verified in zone ${zone} for ${PROMETHEUS_SOURCE}"
        pass "$FIREWALL_RESULT."
        if [[ "$(firewall-cmd --permanent --zone="$zone" --get-target 2>/dev/null || true)" == "ACCEPT" ]]; then
            warn "firewalld zone ${zone} has target ACCEPT; the source-specific rules do not restrict other clients."
        fi
        add_action "Audit existing firewalld rules/services for broader pre-existing access to exporter port(s): ${ports[*]}/tcp."
        return
    fi

    FIREWALL_RESULT="no active UFW/firewalld detected; no rules changed"
    warn "$FIREWALL_RESULT. The installer does not enable a host firewall automatically on a production node."
    add_action "If filtering occurs elsewhere, allow source ${PROMETHEUS_SOURCE} to the enabled exporter port(s): ${ports[*]}/tcp."
}

yaml_target() {
    local address="$1" port="$2"
    if [[ "$address" == *:* ]]; then
        printf '[%s]:%s' "$address" "$port"
    else
        printf '%s:%s' "$address" "$port"
    fi
}

node_label="$(hostname -s 2>/dev/null || hostname)"
{
    printf '# Copy this snippet to the Prometheus server and merge it under scrape_configs.\n'
    printf '# Generated by %s on %s.\n' "$SCRIPT_NAME" "$(timestamp)"
    printf 'scrape_configs:\n'
    if [[ "$DETECTED_MODE" == "full" || "$DETECTED_MODE" == "redis-only" ]]; then
        printf '  - job_name: redis\n'
        printf '    static_configs:\n'
        printf '      - targets: ["%s"]\n' "$(yaml_target "$ADVERTISE_ADDRESS" "$REDIS_EXPORTER_PORT")"
        printf '        labels:\n'
        printf '          node: "%s"\n' "$node_label"
    fi
    if [[ "$DETECTED_MODE" == "full" || "$DETECTED_MODE" == "sentinel-only" ]]; then
        printf '  - job_name: redis-sentinel\n'
        printf '    static_configs:\n'
        printf '      - targets: ["%s"]\n' "$(yaml_target "$ADVERTISE_ADDRESS" "$SENTINEL_EXPORTER_PORT")"
        printf '        labels:\n'
        printf '          node: "%s"\n' "$node_label"
    fi
} >"$PROMETHEUS_SNIPPET"
chown root:redis_exporter "$PROMETHEUS_SNIPPET"
chmod 0640 "$PROMETHEUS_SNIPPET"
pass "Generated Prometheus scrape snippet: $PROMETHEUS_SNIPPET"

configure_firewall

if [[ "$LISTEN_ADDRESS" == "127.0.0.1" || "$LISTEN_ADDRESS" == "::1" ]]; then
    warn "Exporter listens only on loopback; a remote Prometheus server cannot scrape it."
fi

add_action "Copy ${PROMETHEUS_SNIPPET} to the Prometheus server, merge it into scrape_configs, run promtool check config, and reload Prometheus."
add_action "From the Prometheus host, verify HTTP access to ${ADVERTISE_ADDRESS}:${REDIS_EXPORTER_PORT} and/or ${ADVERTISE_ADDRESS}:${SENTINEL_EXPORTER_PORT}."
add_action "In Prometheus, confirm up{job=\"redis\"} and up{job=\"redis-sentinel\"} equal 1 for this node."

TRANSACTION_STARTED=0
finish 0
