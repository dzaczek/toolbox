#!/bin/bash
# Usage: ./snaplist.sh [node_name]
NODE=${1:-$(hostname)}
NOW=$(date +%s)

command -v jq >/dev/null 2>&1 || {
  echo "jq not found. Install with: apt install jq"
  exit 1
}

print_header() {
  printf "%-6s %-30s %-25s %-20s %-8s %s\n" "VMID" "VM Name" "Snapshot" "Created" "Age" "Description"
  echo "----------------------------------------------------------------------------------------------------------------"
}

list_snapshots() {
  local node="$1" vmid="$2" type="$3"
  local path name
  case "$type" in
    qemu) path="qemu";;
    lxc)  path="lxc";;
    *) return;;
  esac

  name=$(pvesh get /nodes/$node/$path/$vmid/config --output-format json 2>/dev/null | jq -r '.name // "unnamed"')

  # get snapshots
  pvesh get /nodes/$node/$path/$vmid/snapshot --output-format json 2>/dev/null | \
  jq -r --arg id "$vmid" --arg name "$name" '
    .[]? | select(.name != "current") |
    "\($id)\t\($name)\t\(.name)\t\(.snaptime // 0)\t\(.description // "no-description")"
  ' | while IFS=$'\t' read -r VMID NAME SNAP SNAPTIME DESC; do
      if [[ $SNAPTIME -gt 0 ]]; then
        CREATED=$(date -d @"$SNAPTIME" +"%Y-%m-%d %H:%M:%S")
        AGE_DAYS=$(( (NOW - SNAPTIME) / 86400 ))d
      else
        CREATED="?"
        AGE_DAYS="?"
      fi
      printf "%-6s %-30s %-25s %-20s %-8s %s\n" "$VMID" "$NAME" "$SNAP" "$CREATED" "$AGE_DAYS" "$DESC"
    done
}

main() {
  print_header
  pvesh get /cluster/resources --output-format json |
  jq -r --arg node "$NODE" '.[] | select(.node == $node) | [.type, .vmid] | @tsv' |
  while IFS=$'\t' read -r TYPE VMID; do
    list_snapshots "$NODE" "$VMID" "$TYPE"
  done
}

main "$@"
