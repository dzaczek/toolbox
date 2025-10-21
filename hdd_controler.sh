#!/bin/bash
echo -e "DISK\tHOST\tPCI_CONTROLLER\tNAME"

# SATA / SAS disks
for dev in /sys/class/block/sd*; do
  [[ -L "$dev" ]] || continue
  disk=$(basename "$dev")
  host=$(readlink -f "$dev" | grep -o 'host[0-9]\+' | head -1)
  [[ -z "$host" ]] && continue
  fullpath=$(readlink -f /sys/class/scsi_host/$host)
  pci_addr=$(echo "$fullpath" | grep -Eo '0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -1)
  name=$(lspci -s "$pci_addr" 2>/dev/null | cut -d' ' -f 2-)
  printf "%s\t%s\t%s\t%s\n" "$disk" "$host" "$pci_addr" "$name"
done

# NVMe disks
for dev in /sys/class/block/nvme*n*; do
  [[ -L "$dev" ]] || continue
  disk=$(basename "$dev")
  fullpath=$(readlink -f "$dev")
  pci_addr=$(echo "$fullpath" | grep -Eo '0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -1)
  name=$(lspci -s "$pci_addr" 2>/dev/null | cut -d' ' -f 2-)
  printf "%s\t%s\t%s\t%s\n" "$disk" "nvme" "$pci_addr" "$name"
done
