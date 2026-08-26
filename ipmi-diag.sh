#!/usr/bin/env bash
#
# ipmi-collect.sh — collect full diagnostics from iLO/BMC over IPMI.
#
# Each category of log / sensor group goes to its own file, each host
# to its own subdirectory. Generates 00_SUMMARY.txt and 00_PROBLEMS.txt
# (only what is out of spec) at the end.
#
# Requires: ipmitool
#   Debian/Ubuntu: apt install ipmitool
#   RHEL/Rocky:    dnf install ipmitool
#   macOS:         brew install ipmitool coreutils
#                  (coreutils provides gtimeout — see TIMEOUT_BIN below)
#

set -uo pipefail

# ============================================================================
# CONFIGURATION — edit below
# ============================================================================

# BMC/iLO hosts. One or many.
HOSTS=(
    "echelon027.infra.us.gov"
    "echelon536.infra.us.gov"
    )

USERNAME="Administrator"
PASSWORD="..........."

# Base output directory (a timestamped subdirectory is created automatically)
OUTPUT_BASE="./ipmi-diag"

# IPMI interface: lanplus (IPMI 2.0 — iLO4/iLO5), lan (IPMI 1.5 — legacy)
IPMI_INTERFACE="lanplus"

# Privilege level: USER | OPERATOR | ADMINISTRATOR
PRIVLVL="ADMINISTRATOR"

# Per-command timeout in seconds. Raise this on a wedged BMC — sensor
# walks can take well over a minute when the BMC is struggling.
CMD_TIMEOUT=120

# ipmitool-level retries and per-packet timeout
IPMI_RETRIES=2
IPMI_TIMEOUT=5

# Also dump SEL in raw format (.sel)? 1 = yes
DUMP_RAW_SEL=1

# Abort the run if DNS resolution for a host starts failing mid-run
# (catches VPN drops that would otherwise look like BMC failures). 1 = yes
ABORT_ON_DNS_LOSS=1

# ============================================================================
# END OF CONFIGURATION
# ============================================================================

# macOS ships no `timeout`; Homebrew coreutils provides `gtimeout`.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    printf 'ERROR: neither timeout nor gtimeout found. On macOS: brew install coreutils\n' >&2
    exit 1
fi

RUN_TS="$(date +%Y-%m-%d_%H%M%S)"
RUN_DIR="${OUTPUT_BASE}/${RUN_TS}"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""; }

DIR=""          # current host's directory
HOST=""         # current host
OK_COUNT=0; FAIL_COUNT=0; DNS_LOST=0

die() { printf '%sERROR:%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

command -v ipmitool >/dev/null 2>&1 || die "ipmitool is not installed."

if [[ "$PASSWORD" == "CHANGE_ME" ]]; then
    die "Set PASSWORD in the configuration section (or export IPMI_PASSWORD and drop this check)."
fi

# ---------------------------------------------------------------------------
# resolves <host> — quick DNS sanity check
# ---------------------------------------------------------------------------
resolves() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$1" >/dev/null 2>&1
    elif command -v dscacheutil >/dev/null 2>&1; then
        dscacheutil -q host -a name "$1" 2>/dev/null | grep -q 'ip_address'
    else
        host "$1" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# run <output_file> <description> <ipmitool args...>
#   Password passed via environment (-E) so it never shows up in ps aux.
# ---------------------------------------------------------------------------
run() {
    local outfile="$1"; shift
    local desc="$1"; shift
    local target="${DIR}/${outfile}"
    local rc

    if [[ "$DNS_LOST" == "1" ]]; then
        printf '  %-42s%s[skipped — DNS]%s\n' "$desc" "$C_DIM" "$C_RST"
        return
    fi

    printf '  %-42s' "$desc"

    IPMI_PASSWORD="$PASSWORD" "$TIMEOUT_BIN" "$CMD_TIMEOUT" \
        ipmitool -I "$IPMI_INTERFACE" -H "$HOST" -U "$USERNAME" -L "$PRIVLVL" -E \
                 -R "$IPMI_RETRIES" -N "$IPMI_TIMEOUT" \
                 "$@" >"$target" 2>"${DIR}/.stderr"
    rc=$?

    {
        printf '### host=%s\n### cmd=ipmitool %s\n### rc=%s  ts=%s\n\n' \
            "$HOST" "$*" "$rc" "$(date -Is 2>/dev/null || date)"
    } >"${DIR}/.hdr"
    cat "$target" >>"${DIR}/.hdr" && mv "${DIR}/.hdr" "$target"

    if [[ $rc -eq 0 && -s "$target" ]]; then
        printf '%s[ok]%s\n' "$C_OK" "$C_RST"
        OK_COUNT=$((OK_COUNT + 1))
    else
        if [[ $rc -eq 124 ]]; then
            printf '%s[timeout]%s\n' "$C_ERR" "$C_RST"
        elif [[ $rc -ne 0 ]]; then
            printf '%s[rc=%s]%s\n' "$C_ERR" "$rc" "$C_RST"
        else
            printf '%s[empty]%s\n' "$C_WARN" "$C_RST"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        {
            printf '=== %s  (rc=%s)\n' "$desc" "$rc"
            printf 'cmd: ipmitool %s\n' "$*"
            sed 's/^/    /' "${DIR}/.stderr"
            printf '\n'
        } >>"${DIR}/99_errors.log"

        # A client-side DNS failure looks identical to a dead BMC in the
        # error log. Detect it and stop, so the report is not misleading.
        if [[ "$ABORT_ON_DNS_LOSS" == "1" ]] \
           && grep -qi 'address lookup\|could not open socket' "${DIR}/.stderr" 2>/dev/null \
           && ! resolves "$HOST"; then
            DNS_LOST=1
            printf '  %sDNS resolution for %s lost — client-side problem, aborting host.%s\n' \
                "$C_ERR" "$HOST" "$C_RST"
            printf '  %sCheck your VPN/resolver, then re-run.%s\n' "$C_ERR" "$C_RST"
            {
                printf '\n!!! DNS resolution lost mid-run at %s\n' "$(date -Is 2>/dev/null || date)"
                printf '!!! Remaining commands were skipped. This is a CLIENT-side failure,\n'
                printf '!!! not evidence of a dead BMC.\n\n'
            } >>"${DIR}/99_errors.log"
        fi
    fi
    rm -f "${DIR}/.stderr"
}

# ---------------------------------------------------------------------------
# count <pattern> <file> — grep -c that always prints a single integer
#   (plain `grep -c ... || echo 0` misbehaves under `set -o pipefail`)
# ---------------------------------------------------------------------------
count() {
    local n
    n=$(grep -icE "$1" "$2" 2>/dev/null) || n=0
    printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------------------
# Analysis: pull out everything that looks like a fault
# ---------------------------------------------------------------------------
analyze() {
    local prob="${DIR}/00_PROBLEMS.txt"

    {
        printf '========================================================\n'
        printf ' DETECTED PROBLEMS — %s\n' "$HOST"
        printf ' generated: %s\n' "$(date -Is 2>/dev/null || date)"
        printf '========================================================\n\n'
    } >"$prob"

    # --- sensors not in "ok" state ---------------------------------------
    printf -- '--- Sensors not in ok state ----------------------------\n' >>"$prob"
    if [[ -s "${DIR}/40_sdr_elist_all.txt" ]]; then
        awk -F'|' '
            /^###/ { next }
            NF >= 3 {
                st = $3; gsub(/^[ \t]+|[ \t]+$/, "", st)
                if (st != "ok" && st != "ns" && st != "" && st !~ /^Status$/) print
            }
        ' "${DIR}/40_sdr_elist_all.txt" >>"$prob" || true
    fi
    printf '\n' >>"$prob"

    # --- sensors with no reading -----------------------------------------
    printf -- '--- Sensors with no reading (ns) — verify --------------\n' >>"$prob"
    if [[ -s "${DIR}/40_sdr_elist_all.txt" ]]; then
        awk -F'|' '/^###/ {next} NF>=3 { st=$3; gsub(/^[ \t]+|[ \t]+$/,"",st); if (st=="ns") print }' \
            "${DIR}/40_sdr_elist_all.txt" >>"$prob" || true
    fi
    printf '\n' >>"$prob"

    # --- BMC health events (crash loop detection) -------------------------
    printf -- '--- BMC availability events ----------------------------\n' >>"$prob"
    if [[ -s "${DIR}/31_sel_elist.txt" ]]; then
        grep -inE 'management controller unavailable|management subsys health|watchdog' \
            "${DIR}/31_sel_elist.txt" >>"$prob" 2>/dev/null || printf '  (none)\n' >>"$prob"
    else
        printf '  (no SEL data)\n' >>"$prob"
    fi
    printf '\n' >>"$prob"

    # --- critical SEL entries ---------------------------------------------
    printf -- '--- SEL: critical entries / faults ---------------------\n' >>"$prob"
    if [[ -s "${DIR}/31_sel_elist.txt" ]]; then
        grep -inE 'critical|non-recoverable|failure|failed|fault|uncorrectable|error|degraded|lost|absent' \
            "${DIR}/31_sel_elist.txt" >>"$prob" 2>/dev/null || printf '  (none)\n' >>"$prob"
    else
        printf '  (no SEL data)\n' >>"$prob"
    fi
    printf '\n' >>"$prob"

    # --- battery / energy pack --------------------------------------------
    printf -- '--- Battery / Smart Storage Energy Pack ----------------\n' >>"$prob"
    grep -ihE 'batt|energy|capacitor|cache' \
        "${DIR}"/4*_sdr_*.txt "${DIR}/50_sensor_list.txt" 2>/dev/null \
        | grep -v '^###' >>"$prob" || printf '  (no entries)\n' >>"$prob"
    printf '\n' >>"$prob"

    # --- power -------------------------------------------------------------
    printf -- '--- Power ----------------------------------------------\n' >>"$prob"
    grep -hiE 'power|fault|interlock|restart cause' \
        "${DIR}/20_chassis_status.txt" "${DIR}/22_chassis_restart_cause.txt" 2>/dev/null \
        | grep -v '^###' >>"$prob" || true
    printf '\n' >>"$prob"

    # --- BMC selftest ------------------------------------------------------
    printf -- '--- BMC selftest ---------------------------------------\n' >>"$prob"
    grep -ihE 'selftest|result|fail' "${DIR}/11_mc_selftest.txt" 2>/dev/null \
        | grep -v '^###' >>"$prob" || printf '  (no data)\n' >>"$prob"
    printf '\n' >>"$prob"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summarize() {
    local sum="${DIR}/00_SUMMARY.txt"
    local bad ns crit bmcfail

    bad=$(awk -F'|' '/^###/{next} NF>=3 {st=$3; gsub(/^[ \t]+|[ \t]+$/,"",st); if (st!="ok" && st!="ns" && st!="") c++} END{print c+0}' \
        "${DIR}/40_sdr_elist_all.txt" 2>/dev/null || echo 0)
    ns=$(awk -F'|' '/^###/{next} NF>=3 {st=$3; gsub(/^[ \t]+|[ \t]+$/,"",st); if (st=="ns") c++} END{print c+0}' \
        "${DIR}/40_sdr_elist_all.txt" 2>/dev/null || echo 0)
    crit=$(count 'critical|non-recoverable|failure|failed|uncorrectable' "${DIR}/31_sel_elist.txt")
    bmcfail=$(count 'management controller unavailable' "${DIR}/31_sel_elist.txt")

    {
        printf '========================================================\n'
        printf ' SUMMARY — %s\n' "$HOST"
        printf ' %s\n' "$(date -Is 2>/dev/null || date)"
        printf '========================================================\n\n'

        printf 'Commands collected:      %s ok / %s failed\n' "$OK_COUNT" "$FAIL_COUNT"
        [[ "$DNS_LOST" == "1" ]] && \
            printf '  NOTE: run aborted early — client-side DNS failure\n'
        printf 'Sensors out of spec:     %s\n' "$bad"
        printf 'Sensors with no reading: %s\n' "$ns"
        printf 'SEL critical entries:    %s\n' "$crit"
        printf 'BMC unavailable events:  %s\n' "$bmcfail"
        [[ "${bmcfail:-0}" -gt 0 ]] && \
            printf '  ^ BMC has been crashing. Sensor data below may be unreliable.\n'
        printf '\n'

        printf -- '--- BMC firmware ---------------------------------------\n'
        grep -iE 'firmware revision|manufacturer name|product name|ipmi version' \
            "${DIR}/10_mc_info.txt" 2>/dev/null || printf '  (none)\n'
        printf '\n'

        printf -- '--- Server ---------------------------------------------\n'
        grep -iE 'product name|serial|manufacturer|part number' \
            "${DIR}/60_fru_print.txt" 2>/dev/null | head -20 || printf '  (none)\n'
        printf '\n'

        printf -- '--- Uptime ---------------------------------------------\n'
        grep -v '^###' "${DIR}/24_chassis_poh.txt" 2>/dev/null || printf '  (none)\n'
        printf '\n'

        printf -- '--- Power ----------------------------------------------\n'
        grep -v '^###' "${DIR}/20_chassis_status.txt" 2>/dev/null | head -20 || printf '  (none)\n'
        printf '\n'

        printf -- '--- SEL ------------------------------------------------\n'
        grep -iE 'entries|percent used|last add' "${DIR}/30_sel_info.txt" 2>/dev/null || printf '  (none)\n'
        printf '\n'

        printf -- '--- Last 15 SEL entries --------------------------------\n'
        grep -v '^###' "${DIR}/31_sel_elist.txt" 2>/dev/null | grep -v '^$' | tail -15 \
            || printf '  (none)\n'
        printf '\n'

        printf 'Fault details:     00_PROBLEMS.txt\n'
        [[ -s "${DIR}/99_errors.log" ]] && printf 'Collection errors: 99_errors.log\n'
    } >"$sum"
}

# ---------------------------------------------------------------------------
# Collect from a single host
# ---------------------------------------------------------------------------
collect_host() {
    HOST="$1"
    DIR="${RUN_DIR}/${HOST}"
    OK_COUNT=0; FAIL_COUNT=0; DNS_LOST=0

    mkdir -p "$DIR" || die "cannot create $DIR"

    printf '\n%s>>> %s%s\n' "$C_OK" "$HOST" "$C_RST"

    # --- connectivity probe ----------------------------------------------
    printf '  %-42s' "connectivity probe (mc info)"
    if ! IPMI_PASSWORD="$PASSWORD" "$TIMEOUT_BIN" 20 \
        ipmitool -I "$IPMI_INTERFACE" -H "$HOST" -U "$USERNAME" -L "$PRIVLVL" -E \
                 -R 1 -N 3 mc info >/dev/null 2>"${DIR}/.probe"; then
        printf '%s[UNREACHABLE]%s\n' "$C_ERR" "$C_RST"
        {
            printf 'Host %s did not respond over IPMI.\n\n' "$HOST"
            sed 's/^/    /' "${DIR}/.probe"
            printf '\nCheck:\n'
            printf '  - is 623/udp open:  nmap -Pn -sU -p 623 %s\n' "$HOST"
            printf '  - is IPMI over LAN enabled in iLO\n'
            printf '  - credentials and privilege level\n'
            printf '  - your own DNS/VPN\n'
        } >"${DIR}/00_UNREACHABLE.txt"
        rm -f "${DIR}/.probe"
        return 1
    fi
    rm -f "${DIR}/.probe"
    printf '%s[ok]%s\n' "$C_OK" "$C_RST"

    # --- BMC --------------------------------------------------------------
    run 10_mc_info.txt            "BMC: info"                mc info
    run 11_mc_selftest.txt        "BMC: selftest"            mc selftest
    run 12_mc_watchdog.txt        "BMC: watchdog"            mc watchdog get
    run 13_mc_guid.txt            "BMC: GUID"                mc guid
    run 14_bmc_getenables.txt     "BMC: global enables"      mc getenables

    # --- chassis / power ---------------------------------------------------
    run 20_chassis_status.txt     "Chassis: status"          chassis status
    run 21_chassis_power.txt      "Chassis: power status"    chassis power status
    run 22_chassis_restart_cause.txt "Chassis: restart cause" chassis restart_cause
    run 23_chassis_bootparam.txt  "Chassis: boot params"     chassis bootparam get 5
    run 24_chassis_poh.txt        "Chassis: power-on hours"  chassis poh
    run 25_dcmi_power.txt         "DCMI: power reading"      dcmi power reading

    # --- SEL ---------------------------------------------------------------
    run 30_sel_info.txt           "SEL: info"                sel info
    run 31_sel_elist.txt          "SEL: extended list"       sel elist
    run 32_sel_list.txt           "SEL: raw list"            sel list

    if [[ "$DUMP_RAW_SEL" == "1" && "$DNS_LOST" != "1" ]]; then
        printf '  %-42s' "SEL: binary dump"
        if IPMI_PASSWORD="$PASSWORD" "$TIMEOUT_BIN" "$CMD_TIMEOUT" \
            ipmitool -I "$IPMI_INTERFACE" -H "$HOST" -U "$USERNAME" -L "$PRIVLVL" -E \
                     sel save "${DIR}/33_sel_raw.sel" >/dev/null 2>&1; then
            printf '%s[ok]%s\n' "$C_OK" "$C_RST"
        else
            printf '%s[skipped]%s\n' "$C_WARN" "$C_RST"
        fi
    fi

    # --- sensors: aggregate -------------------------------------------------
    run 40_sdr_elist_all.txt      "SDR: all (elist)"         sdr elist all
    run 41_sdr_elist_full.txt     "SDR: full"                sdr elist full
    run 42_sdr_info.txt           "SDR: repository info"     sdr info

    # --- sensors: by type (separate files) ----------------------------------
    run 43_sdr_temperature.txt    "SDR: temperature"         sdr type Temperature
    run 44_sdr_fan.txt            "SDR: fans"                sdr type Fan
    run 45_sdr_voltage.txt        "SDR: voltage"             sdr type Voltage
    run 46_sdr_power_supply.txt   "SDR: power supplies"      sdr type "Power Supply"
    run 47_sdr_memory.txt         "SDR: memory"              sdr type Memory
    run 48_sdr_processor.txt      "SDR: processors"          sdr type Processor
    run 49_sdr_battery.txt        "SDR: battery/energy pack" sdr type Battery
    run 4a_sdr_drive_slot.txt     "SDR: drive slots"         sdr type "Drive Slot"
    run 4b_sdr_current.txt        "SDR: current"             sdr type Current
    run 4c_sdr_phys_security.txt  "SDR: physical security"   sdr type "Physical Security"
    run 4d_sdr_module.txt         "SDR: modules"             sdr type "Module/Board"
    run 4e_sdr_watchdog.txt       "SDR: watchdog"            sdr type "Watchdog2"

    # --- everything else ----------------------------------------------------
    run 50_sensor_list.txt        "Sensor: full list"        sensor list
    run 60_fru_print.txt          "FRU: inventory"           fru print
    run 70_lan_print.txt          "LAN: channel 1 config"    lan print 1
    run 71_lan_print_2.txt        "LAN: channel 2 config"    lan print 2
    run 72_lan_alert.txt          "LAN: alert destinations"  lan alert print 1
    run 80_user_list.txt          "Users: list"              user list 1
    run 81_channel_info.txt       "Channel: info"            channel info 1
    run 82_channel_access.txt     "Channel: access"          channel getaccess 1
    run 83_session_info.txt       "Sessions: active"         session info all
    run 90_sol_info.txt           "SOL: config"              sol info
    run 91_pef_info.txt           "PEF: info"                pef info
    run 92_pef_policy.txt         "PEF: policies"            pef policy list

    analyze
    summarize

    printf '  %s-> %s%s\n' "$C_DIM" "$DIR" "$C_RST"

    local bmcfail
    bmcfail=$(count 'management controller unavailable' "${DIR}/31_sel_elist.txt")
    if [[ "${bmcfail:-0}" -gt 0 ]]; then
        printf '  %s!! %s BMC-unavailable events in SEL — BMC is crashing%s\n' \
            "$C_ERR" "$bmcfail" "$C_RST"
    fi

    local bad
    bad=$(count '^[^-=# ].*\|' "${DIR}/00_PROBLEMS.txt")
    if [[ "${bad:-0}" -gt 0 ]]; then
        printf '  %s!  entries needing attention — see 00_PROBLEMS.txt%s\n' "$C_WARN" "$C_RST"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"

printf '%sIPMI diagnostics%s — %s host(s), output: %s\n' \
    "$C_OK" "$C_RST" "${#HOSTS[@]}" "$RUN_DIR"

FAILED_HOSTS=()
for h in "${HOSTS[@]}"; do
    collect_host "$h" || FAILED_HOSTS+=("$h")
done

# run-wide index
{
    printf 'IPMI diagnostics — %s\n' "$(date -Is 2>/dev/null || date)"
    printf 'Hosts: %s\n\n' "${#HOSTS[@]}"
    for h in "${HOSTS[@]}"; do
        printf '=== %s\n' "$h"
        if [[ -f "${RUN_DIR}/${h}/00_UNREACHABLE.txt" ]]; then
            printf '    UNREACHABLE over IPMI\n\n'
        else
            grep -E 'Sensors|SEL critical|BMC unavailable|Commands collected' \
                "${RUN_DIR}/${h}/00_SUMMARY.txt" 2>/dev/null | sed 's/^/    /'
            printf '\n'
        fi
    done
} >"${RUN_DIR}/00_INDEX.txt"

printf '\n%sDone.%s Index: %s/00_INDEX.txt\n' "$C_OK" "$C_RST" "$RUN_DIR"
if [[ ${#FAILED_HOSTS[@]} -gt 0 ]]; then
    printf '%sUnreachable:%s %s\n' "$C_ERR" "$C_RST" "${FAILED_HOSTS[*]}"
    exit 1
fi
