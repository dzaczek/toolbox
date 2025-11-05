#!/usr/bin/env bash
# 02/21

set -e

set -u

set -o pipefail


#set -euo pipefail


: "${ILO_IP:?set ILO_IP}"
: "${ILO_ADMIN_USER:?set ILO_ADMIN_USER}"
: "${ILO_ADMIN_PASS:?set ILO_ADMIN_PASS}"
: "${ILO_NEW_PASS:?set ILO_NEW_PASS}"

NEW_USER="vz2ilo"
NEW_PASS="${ILO_NEW_PASS}"

# ipmitool without exposing admin pass in ps (still required for some setups)
export IPMI_PASSWORD="${ILO_ADMIN_PASS}"
IPMI_ARGS=(-I lanplus -H "${ILO_IP}" -U "${ILO_ADMIN_USER}" -E)

command -v ipmitool >/dev/null 2>&1 || { echo "ipmitool not found"; exit 1; }

# --- Helpers ---
die(){ echo "Error: $*" >&2; exit 1; }

check_name_len() {
  local name="$1"
  local max=16
  [ "${#name}" -le "${max}" ] || die "Username '${name}' longer than ${max} chars (IPMI limit)."
}

detect_channel() {
  echo "Detecting active LAN channel..."
  for ch in $(seq 1 16); do
    if ipmitool "${IPMI_ARGS[@]}" channel info "$ch" 2>/dev/null | grep -q "Medium Type: 802.3 LAN"; then
      echo "$ch"; return 0
    fi
  done
  return 1
}

find_free_user_id() {
  # Parse first blank Name in `user list <chan>`
  local ch="$1"
  ipmitool "${IPMI_ARGS[@]}" user list "${ch}" \
  | awk 'NR>1{
      id=$1;
      # "Name" is a fixed-width field starting at col 6; trim spaces
      name=substr($0,6,16); gsub(/^ *| *$/,"",name);
      if (name==""){ print id; exit }
    }'
}

user_exists() {
  local ch="$1" user="$2"
  ipmitool "${IPMI_ARGS[@]}" user list "${ch}" | awk 'NR>1{print $0}' | grep -qw -- "$user"
}

# --- Main ---
check_name_len "${NEW_USER}"

CHANNEL="$(detect_channel)" || die "No active LAN channel on ${ILO_IP}. Check creds/network."
echo "Using channel ${CHANNEL}"

echo "Checking if '${NEW_USER}' exists..."
if user_exists "${CHANNEL}" "${NEW_USER}"; then
  echo "User '${NEW_USER}' already present on channel ${CHANNEL}. Nothing to do."
  exit 0
fi

echo "Finding a free user slot..."
USER_ID="$(find_free_user_id "${CHANNEL}")"
[ -n "${USER_ID}" ] || die "No free user slots available on ${ILO_IP}."

echo "Creating user '${NEW_USER}' with ID ${USER_ID}..."
ipmitool "${IPMI_ARGS[@]}" user set name "${USER_ID}" "${NEW_USER}"
ipmitool "${IPMI_ARGS[@]}" user set password "${USER_ID}" "${NEW_PASS}"

# Set USER privilege (2) and ensure channel access flags are sane
ipmitool "${IPMI_ARGS[@]}" user priv "${USER_ID}" 2 "${CHANNEL}"
ipmitool "${IPMI_ARGS[@]}" channel setaccess "${CHANNEL}" "${USER_ID}" callin=on link=on ipmi=on privilege=2
ipmitool "${IPMI_ARGS[@]}" user enable "${USER_ID}"

echo "Verifying..."
ipmitool "${IPMI_ARGS[@]}" user list "${CHANNEL}" | awk -v u="${NEW_USER}" '$0 ~ u {print; found=1} END{exit found?0:1}' \
  || die "User not visible after creation."

echo "Success: '${NEW_USER}' created with USER privilege on channel ${CHANNEL} (ID ${USER_ID})."
