#!/usr/bin/env bash
# vcpu-by-node.sh — per-node vCPU sum + host CPUs
# Usage: ./vcpu-by-node.sh [--running|-r|--runing]

set -euo pipefail

running=false
case "${1:-}" in
  -r|--running|--runing) running=true ;;
  "" ) ;;
  * ) echo "Usage: $0 [--running|-r]"; exit 1 ;;
esac

printf "%-20s %-16s %-12s\n" "NODE" "ALLOCATED_vCPUs" "HOST_CPUs"
printf "%-20s %-16s %-12s\n" "----" "----------------" "---------"


nodes_json=$(pvesh get /nodes --output-format json)

while IFS=$'\t' read -r node status hostcpu; do
  if [[ "$status" != "online" ]]; then
    printf "%-20s %-16s %-12s\n" "$node" "OFFLINE" "$hostcpu"
    continue
  fi

  if $running; then
    alloc=$(pvesh get /nodes/$node/qemu --output-format json \
      | jq '[.[] | select(.status=="running") | (.cpus // .maxcpu // 0)] | add // 0' \
      || echo 0)
  else
    alloc=$(pvesh get /nodes/$node/qemu --output-format json \
      | jq '[.[] | (.cpus // .maxcpu // 0)] | add // 0' \
      || echo 0)
  fi

  printf "%-20s %-16s %-12s\n" "$node" "$alloc" "$hostcpu"
done < <(
  jq -r 'sort_by(.node)[] | "\(.node)\t\(.status)\t\(.maxcpu // 0)"' <<<"$nodes_json"
)
