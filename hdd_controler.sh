#!/bin/bash
#Test version 
echo -e "DISK\tHOST\tPCI_CONTROLLER\tNAME"

# --- handle SATA/SAS disks ---
for dev in /sys/class/block/sd*; do
  disk=$(basename "$dev")
  host=$(readlink -f "$dev" | grep -o 'host[0-9]\+' | head -1)
  [[ -z "$host" ]] && continue
      pci_path=$(readlink -f /sys/class/scsi_host/$host | grep -o '/0000:[0-9a-f:.]\+' | tail -1)
      pci_addr=$(basename "$pci_path")
      name=$(lspci -s "$pci_addr" 2>/dev/null | cut -d' ' -f 2-)
    printf "%s\t%s\t%s\t%s\n" "$disk" "$host" "$pci_addr" "$name"
done

# --- handle NVMe disks ---
for dev in /sys/class/block/nvme*n*; do
      disk=$(basename "$dev")
  pci_path=$(readlink -f "$dev" | grep -o '/0000:[0-9a-f:.]\+' | tail -1)
      pci_addr=$(basename "$pci_path")
  name=$(lspci -s "$pci_addr" 2>/dev/null | cut -d' ' -f 2-)
  printf "%s\t%s\t%s\t%s\n" "$disk" "nvme" "$pci_addr" "$name"
done
