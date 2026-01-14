#!/bin/bash
# Proxmox disk vm location audit tool 
# --- CHECKING FOR PAPA SMURF ---
# Only Papa Smurf (root) has the magical ingredients to run this.
if [ "$EUID" -ne 0 ]; then
  echo "⛔ Halt! Gargamel is watching! You must be Papa Smurf (root) to cast this spell."
  exit 1
fi

# --- CHECKING THE VILLAGE ---
# Are we actually in the Smurf Village (Proxmox)?
if ! command -v qm &> /dev/null; then
    echo "🍄 Wait a smurfing minute... I can't find 'qm'. This doesn't look like Proxmox Village!"
    exit 1
fi

declare -A storage_map

echo "🔎 Grabbing the magnifying glass..."
echo "🌲 Hunting for little blue VM disks hiding in the storage forest..."
echo "----------------------------------------------------------------"

# Looping through every mushroom house (VM)
while read -r vmid name; do
    
    # Peeking inside the window of the VM configuration
    # We are looking for things like scsi, sata, virtio (the furniture)
    config_disks=$(qm config "$vmid" | grep -E '^(scsi|sata|virtio|ide)[0-9]+:')

    # If the house is empty, move to the next mushroom
    if [ -z "$config_disks" ]; then
        continue
    fi

    # Analyzing where the furniture came from (Storage ID)
    while read -r line; do
        # Extracting the storage name using magic scissors (awk)
        storage=$(echo "$line" | awk -F': ' '{print $2}' | awk -F':' '{print $1}')
        
        # We don't care about shiny mirrors (CD-ROMs), only real hard disks!
        if [[ "$line" == *"media=cdrom"* ]]; then
            continue
        fi

        # Add this Smurf to the map if not already listed
        # We want to know which VM lives in which Storage Area
        if [[ "${storage_map[$storage]}" != *"$vmid ($name)"* ]]; then
            storage_map["$storage"]+="$vmid ($name)\n"
        fi

    done <<< "$config_disks"

done < <(qm list | awk '$1 ~ /^[0-9]+/ {print $1, $2}')

# --- THE GRAND REVEAL ---
echo ""
echo "🎉 EUREKA! I found where they are hiding!"
echo "=== 🍄 THE SMURF VILLAGE STORAGE MAP 🍄 ==="
echo ""

# Sorting the locations and printing the list
for storage in $(echo "${!storage_map[@]}" | tr ' ' '\n' | sort); do
    echo "🏠 Storage Location: [$storage]"
    echo "   (Look who is hiding in here:)"
    echo "---------------------------------"
    # -e makes sure the newlines are printed correctly
    echo -e "${storage_map[$storage]}" | sort -n
    echo ""
done

echo "👋 Smurf you later!"
