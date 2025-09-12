#!/usr/bin/env bash
# pve-vcpu-sum.sh — sum allocated vCPUs for VMs on this node
# Usage:
#   ./pve-vcpu-sum.sh            # all VMs on this node
#   ./pve-vcpu-sum.sh --running  # only VMs that are running
#   ./pve-vcpu-sum.sh --quiet    # print total only (no per-VM rows)

set -euo pipefail

running_only=false
quiet=false
for arg in "$@"; do
  case "$arg" in
    -r|--running) running_only=true ;;
    -q|--quiet)   quiet=true ;;
    -h|--help)
      echo "Usage: $0 [--running] [--quiet]"
      exit 0
      ;;
  esac
done

# Collect VMIDs present on this node
if $running_only; then
  mapfile -t VMIDS < <(qm list | awk 'NR>1 && $3=="running"{print $1}')
else
  mapfile -t VMIDS < <(qm list | awk 'NR>1 {print $1}')
fi

total=0
rows=()

for id in "${VMIDS[@]}"; do
  cfg=$(qm config "$id")
  name=$(awk -F': ' '/^name:/{print $2}' <<<"$cfg")
  [[ -z "${name:-}" ]] && name="vm${id}"

  # Prefer 'vcpus' if present; else sockets*cores (defaults 1)
  vcpus=$(awk -F': ' '/^vcpus:/{print $2}' <<<"$cfg" || true)
  if [[ -n "${vcpus:-}" ]]; then
    cpu="$vcpus"
    note="(vcpus)"
  else
    sockets=$(awk -F': ' '/^sockets:/{print $2}' <<<"$cfg" || true); sockets=${sockets:-1}
    cores=$(awk -F': ' '/^cores:/{print $2}' <<<"$cfg" || true);   cores=${cores:-1}
    cpu=$(( sockets * cores ))
    note="(sockets*cores)"
  fi

  total=$(( total + cpu ))
  rows+=("$id|$name|$cpu|$note")
done

if ! $quiet; then
  printf "%-8s %-30s %-8s %s\n" "VMID" "NAME" "vCPUs" "SOURCE"
  printf "%-8s %-30s %-8s %s\n" "----" "------------------------------" "-----" "------"
  for r in "${rows[@]}"; do
    IFS='|' read -r id name cpu note <<<"$r"
    printf "%-8s %-30s %-8s %s\n" "$id" "$name" "$cpu" "$note"
  done
  echo "--------------------------------------------------------------"
fi

echo "TOTAL_vCPUs=${total}"
