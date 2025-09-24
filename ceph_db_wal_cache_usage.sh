#!/usr/bin/env bash
set -euo pipefail

# Ceph per-OSD DB/WAL usage + BlueStore/BlueFS cache + memory target
# Node-aware (Option B): keeps only OSDs whose CRUSH 'host' == this node (or --node override).
# Needs: ceph, jq, awk

# -------- args --------
NODE_OVERRIDE=""
SCAN_ALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE_OVERRIDE="${2:-}"; shift 2;;
    --all)  SCAN_ALL=true; shift;;
    -h|--help)
      cat <<'USAGE'
Usage: ceph-osd-mem-dbwal.sh [--node <crush-host>] [--all]
  --node <crush-host>  : treat this CRUSH host name as "local"
  --all                : do not filter; scan every OSD in the cluster
USAGE
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# -------- util --------
bytes_to_gib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", int(b/1073741824)}'; }
bytes_to_mib() { awk -v b="${1:-0}" 'BEGIN{printf "%d", int(b/1048576)}'; }

# Safe single-key fetch; returns empty if unset
ceph_get_cfg() {
  local who="$1" key="$2" val=""
  if val="$(ceph config get "$who" "$key" 2>/dev/null | tr -d '[:space:]')"; then
    echo "$val"; return 0
  fi
  if val="$(ceph config get mon "$key" 2>/dev/null | tr -d '[:space:]')"; then
    echo "$val"; return 0
  fi
  echo ""
}

get_osd_mem_target_bytes() {
  local osd="$1" v auto=""
  v="$(ceph_get_cfg "osd.$osd" osd_memory_target)"
  auto="$(ceph_get_cfg "osd.$osd" osd_memory_target_autotune)"
  if [[ -n "$v" && "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
    echo "$v osd_memory_target ${auto:-false}"; return
  fi
  v="$(ceph_get_cfg "osd.$osd" bluestore_cache_size)"
  if [[ -n "$v" && "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
    echo "$v bluestore_cache_size false"; return
  fi
  local vh vs
  vh="$(ceph_get_cfg "osd.$osd" bluestore_cache_size_hdd)"; [[ "$vh" =~ ^[0-9]+$ ]] || vh=0
  vs="$(ceph_get_cfg "osd.$osd" bluestore_cache_size_ssd)"; [[ "$vs" =~ ^[0-9]+$ ]] || vs=0
  if (( vh>0 || vs>0 )); then
    if (( vs > vh )); then echo "$vs bluestore_cache_size_ssd false"; else echo "$vh bluestore_cache_size_hdd false"; fi
    return
  fi
  echo "4294967296 default false"   # ~4 GiB fallback
}

# Determine if the given OSD belongs to the "local" node (CRUSH host)
LOCAL_SHORT="$(hostname -s || true)"; LOCAL_FQDN="$(hostname -f || true)"; LOCAL_HOST="$(hostname || true)"
is_local_osd() {
  $SCAN_ALL && return 0
  local id="$1" host
  host="$(ceph osd find "$id" -f json 2>/dev/null | jq -r '.crush_location.host // empty')"
  [[ -z "$host" ]] && return 1
  if [[ -n "$NODE_OVERRIDE" ]]; then
    [[ "$host" == "$NODE_OVERRIDE" ]] && return 0 || return 1
  fi
  # match against typical hostname variants; normalize to shortname too
  local short="${LOCAL_SHORT%%.*}"
  if [[ "$host" == "$LOCAL_SHORT" || "$host" == "$LOCAL_FQDN" || "$host" == "$LOCAL_HOST" || "$host" == "${short}" ]]; then
    return 0
  fi
  return 1
}

# -------- totals --------
tot_db_used=0; tot_db_total=0; tot_db_res=0
tot_wal_used=0; tot_wal_total=0; tot_wal_res=0
tot_cache_bytes=0; tot_mem_target=0

echo "== Per-OSD BlueFS/BlueStore usage & memory =="

# Loop all OSDs but act only on those mapped to this node (unless --all)
for i in $(ceph osd ls); do
  if ! is_local_osd "$i"; then
    continue
  fi

  PERF_JSON="$(ceph daemon osd.$i perf dump 2>/dev/null || true)"
  [[ -z "$PERF_JSON" ]] && { echo "osd.$i  (no perf dump available)"; continue; }

  # Extract metrics
  read -r du dt dr wu wt wr cache_bytes cache_brief <<<"$(jq -r '
    def n: (tonumber? // 0);
    def find($k): [.. | objects | select(has($k)) | .[$k]] | first;

    (find("db_used_bytes")  | n) as $du |
    (find("db_total_bytes") | n) as $dt |
    (find("wal_used_bytes") | n) as $wu |
    (find("wal_total_bytes")| n) as $wt |

    ((find("bluefs_db_reserved_bytes")  // find("bluestore_db_reserved")  // 0) | n) as $dr |
    ((find("bluefs_wal_reserved_bytes") // find("bluestore_wal_reserved") // 0) | n) as $wr |

    def cache_sum:
      [ .. | objects
          | to_entries[]
          | select(
              (.key|test("(^bstore_cache_.*_bytes$)")) or
              (.key|test("(^bluestore_cache_.*_bytes$)")) or
              (.key|test("(^bluefs_.*_bytes$)")) or
              (.key|test("(^rocksdb_block_cache_.*_bytes$)"))
            )
          | (.value | n)
        ] | add // 0;

    def cache_top2:
      ( [ .. | objects
            | to_entries[]
            | select(
                (.key|test("(^bstore_cache_.*_bytes$)")) or
                (.key|test("(^bluestore_cache_.*_bytes$)")) or
                (.key|test("(^bluefs_.*_bytes$)")) or
                (.key|test("(^rocksdb_block_cache_.*_bytes$)"))
              )
            | {k:.key, v:(.value|n)}
          ]
        | sort_by(-.v) | .[0:2]
        | map("\(.k)=\(.v|tostring)") | join(", ")
      ) // "" ;

    ( $du|tostring ) + " " + ( $dt|tostring ) + " " + ( $dr|tostring ) + " " +
    ( $wu|tostring ) + " " + ( $wt|tostring ) + " " + ( $wr|tostring ) + " " +
    ( cache_sum|tostring ) + " " + ( cache_top2 )
  ' <<<"$PERF_JSON")"

  read -r mem_target mem_src autotune <<<"$(get_osd_mem_target_bytes "$i")"

  # Totals
  tot_db_used=$(( tot_db_used + du ))
  tot_db_total=$(( tot_db_total + dt ))
  tot_db_res=$(( tot_db_res + dr ))
  tot_wal_used=$(( tot_wal_used + wu ))
  tot_wal_total=$(( tot_wal_total + wt ))
  tot_wal_res=$(( tot_wal_res + wr ))
  tot_cache_bytes=$(( tot_cache_bytes + cache_bytes ))
  tot_mem_target=$(( tot_mem_target + mem_target ))

  # Pretty
  du_g=$(bytes_to_gib "$du"); dt_g=$(bytes_to_gib "$dt")
  wu_g=$(bytes_to_gib "$wu"); wt_g=$(bytes_to_gib "$wt")
  dr_g=$(bytes_to_gib "$dr"); wr_g=$(bytes_to_gib "$wr")
  cache_m=$(bytes_to_mib "$cache_bytes")
  mtarget_g=$(bytes_to_gib "$mem_target")

  db_pct="NA"; wal_pct="NA"; cache_vs_target="NA"
  [[ "$dt" -gt 0 ]] && db_pct=$(( du*100/dt ))
  [[ "$wt" -gt 0 ]] && wal_pct=$(( wu*100/wt ))
  [[ "$mem_target" -gt 0 ]] && cache_vs_target=$(( cache_bytes*100/mem_target ))
  headroom_mib=$(( (mem_target - cache_bytes) / 1048576 ))

  printf "osd.%-3s  db=%s/%sGiB(res=%sGiB) db_pct=%s%%  wal=%s/%sGiB(res=%sGiB) wal_pct=%s%%  cache=%sMiB  target=%sGiB(%s)  cache%%=~%s%%  headroom=~%dMiB" \
    "$i" "$du_g" "$dt_g" "$dr_g" "$db_pct" \
    "$wu_g" "$wt_g" "$wr_g" "$wal_pct" \
    "$cache_m" "$mtarget_g" "$mem_src" "$cache_vs_target" "$headroom_mib"

  if (( cache_bytes > mem_target )); then printf "  [HOT]"; fi
  [[ -n "${cache_brief// }" ]] && printf "  [%s]" "$cache_brief"
  printf "\n"
done

echo
echo "== Cluster summary =="

if OSD_DF_JSON="$(ceph osd df --format json 2>/dev/null || true)"; [[ -n "$OSD_DF_JSON" ]]; then
  read -r raw_kb raw_kb_used <<<"$(jq -r '
    (.nodes // []) as $n |
    ( [$n[]?.kb]      | add // 0 ) as $kb |
    ( [$n[]?.kb_used] | add // 0 ) as $used |
    "\($kb) \($used)"
  ' <<<"$OSD_DF_JSON")"
  raw_total_bytes=$(( raw_kb * 1024 ))
  raw_used_bytes=$(( raw_kb_used * 1024 ))
  raw_pct=$([[ $raw_total_bytes -gt 0 ]] && awk -v u="$raw_used_bytes" -v t="$raw_total_bytes" 'BEGIN{printf "%d", (u*100)/t}' || echo "NA")
  printf "RAW: used=%d/%dGiB (%s%%)\n" "$(bytes_to_gib "$raw_used_bytes")" "$(bytes_to_gib "$raw_total_bytes")" "$raw_pct"
else
  echo "RAW: (ceph osd df unavailable)"
fi

db_pct="NA"; wal_pct="NA"
[[ "$tot_db_total" -gt 0 ]] && db_pct=$(( tot_db_used*100/tot_db_total ))
[[ "$tot_wal_total" -gt 0 ]] && wal_pct=$(( tot_wal_used*100/tot_wal_total ))

printf "BlueFS DB:  used=%d/%dGiB (res=%dGiB) (%s%% used)\n" \
  "$(bytes_to_gib "$tot_db_used")" "$(bytes_to_gib "$tot_db_total")" "$(bytes_to_gib "$tot_db_res")" "$db_pct"
printf "BlueFS WAL: used=%d/%dGiB (res=%dGiB) (%s%% used)\n" \
  "$(bytes_to_gib "$tot_wal_used")" "$(bytes_to_gib "$tot_wal_total")" "$(bytes_to_gib "$tot_wal_res")" "$wal_pct"

printf "Cache RAM (BlueStore/BlueFS): ~%dMiB total across OSDs\n" "$(bytes_to_mib "$tot_cache_bytes")"
printf "OSD memory targets (sum): ~%dGiB; cache vs target ~= %s%%\n" \
  "$(bytes_to_gib "$tot_mem_target")" \
  "$([[ $tot_mem_target -gt 0 ]] && awk -v c="$tot_cache_bytes" -v t="$tot_mem_target" 'BEGIN{printf "%d", (c*100)/t}' || echo "NA")"
