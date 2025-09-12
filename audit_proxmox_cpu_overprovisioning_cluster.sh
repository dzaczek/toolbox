#!/bin/bash
printf "%-20s %-14s %-12s\n" "NODE" "ALLOCATED_vCPUs" "HOST_CPUs"
printf "%-20s %-14s %-12s\n" "----" "--------------" "---------"

declare -A HOSTCPU
while IFS=$'\t' read -r node maxcpu; do
  HOSTCPU["$node"]="$maxcpu"
done < <(pvesh get /cluster/resources --type node --output-format json \
         | jq -r '.[] | select(.type=="node") | "\(.node)\t\(.maxcpu // 0)"')


for n in $(pvesh get /nodes --output-format json | jq -r '.[].node' | sort); do
  alloc=$(pvesh get /nodes/$n/qemu --output-format json \
          | jq '[.[].cpus] | add // 0')
  host=${HOSTCPU[$n]:-0}
  printf "%-20s %-14s %-12s\n" "$n" "$alloc" "$host"
done
