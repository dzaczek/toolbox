
#!/usr/bin/env bash
# Create iLO user with only "Login" privilege (USER level)
# Requires: ipmitool

ILO_IP="10.10.10.10"      # <-- set iLO IP
ILO_USER="admin"    # <-- set admin user
ILO_PASS="secret"           # <-- set admin password

NEW_USER="RamRam"
NEW_PASS="${ILO_NEW_PASS}"   # pass from env var

# Detect channel with LAN support
detect_channel() {
    for ch in $(seq 1 16); do
        if ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" channel info $ch 2>/dev/null | grep -q "Medium Type: 802.3 LAN"; then
            echo $ch
            return
        fi
    done
}

CHANNEL=$(detect_channel)

if [ -z "$CHANNEL" ]; then
    echo "Error: no active LAN channel found on $ILO_IP"
    exit 1
fi

echo "Using channel $CHANNEL"

# Check if user already exists
if ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user list $CHANNEL | grep -q "$NEW_USER"; then
    echo "User $NEW_USER already exists on $ILO_IP (channel $CHANNEL)"
    exit 0
fi

# Find next free user ID slot
USER_ID=$(ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user list $CHANNEL \
           | awk 'NR>1 && $2=="false"{print $1; exit}')

if [ -z "$USER_ID" ]; then
    echo "Error: no free user slots available on $ILO_IP"
    exit 1
fi

echo "Creating user $NEW_USER with ID $USER_ID"

# Create user
ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user set name $USER_ID "$NEW_USER"
ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user set password $USER_ID "$NEW_PASS"

# Set privilege level to USER (only Login, no power/reset/console etc.)
ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user priv $USER_ID 2 $CHANNEL

# Enable user
ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" user enable $USER_ID

echo "User $NEW_USER created with USER privileges (Login only) on channel $CHANNEL."

