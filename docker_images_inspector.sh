#!/usr/bin/env bash
#
# images-check.sh
# ---------------
# Produces two reports:
#   images-in-use.txt   – images referenced by containers or used as parents
#   images-unused.txt   – images that nothing else depends on (safe to delete)
#
# Requirements:
#   • Bash 4+ with sudo access to Docker
#
set -euo pipefail

echo "Gathering data, please wait ..."

##############################################################################
# Step 1 – Map: IMAGE_ID  ->  repo:tag,repo:tag,...
##############################################################################
declare -A TAGS

while read -r id tag; do
    TAGS["$id"]+="${TAGS[$id]:+,}$tag"
done < <(
    sudo docker images --no-trunc \
        --format '{{.ID}} {{.Repository}}:{{.Tag}}'
)

##############################################################################
# Step 2 – Images referenced by ANY container (running OR stopped)
##############################################################################
declare -A REASONS
while read -r cid; do
    img_id=$(sudo docker inspect --format '{{.Image}}' "$cid")
    cname=$(sudo docker inspect --format '{{.Name}}'  "$cid" | cut -c2-)
    REASONS["$img_id"]+="${REASONS[$img_id]:+ ; }container:${cname}"
done < <(sudo docker ps -a -q)

##############################################################################
# Step 3 – Parent/child relationships between local images
##############################################################################
while read -r img_id; do
    parent=$(sudo docker inspect --format '{{.Parent}}' "$img_id" 2>/dev/null || true)
    if [[ -n "$parent" && "$parent" != "<nil>" ]]; then
        child_tag="${TAGS[$img_id]:-$img_id}"
        REASONS["$parent"]+="${REASONS[$parent]:+ ; }child:${child_tag}"
    fi
done < <(printf '%s\n' "${!TAGS[@]}")

##############################################################################
# Step 4 – Write images-in-use.txt
##############################################################################
{
    printf -- 'IMAGE (repo:tag or ID) | REASON(S)\n'
    printf -- '-----------------------------------\n'
    for img_id in "${!REASONS[@]}"; do
        printf -- '%s | %s\n' "${TAGS[$img_id]:-$img_id}" "${REASONS[$img_id]}"
    done | sort
} > images-in-use.txt

##############################################################################
# Step 5 – Write images-unused.txt
##############################################################################
{
    printf -- 'IMAGE (repo:tag or ID)\n'
    printf -- '----------------------\n'
    for img_id in "${!TAGS[@]}"; do
        if [[ ! -v REASONS[$img_id] ]]; then
            printf -- '%s\n' "${TAGS[$img_id]:-$img_id}"
        fi
    done | sort
} > images-unused.txt

##############################################################################
# Step 6 – Summary
##############################################################################
echo
echo "Report completed:"
echo " • images-in-use.txt   : $(wc -l < images-in-use.txt) lines"
echo " • images-unused.txt   : $(wc -l < images-unused.txt) lines"
echo
echo "To delete everything in images-unused.txt, review it, then run:"
echo "   xargs -a images-unused.txt sudo docker rmi"
