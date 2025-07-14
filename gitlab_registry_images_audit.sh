#!/bin/bash
# Description:
# This script performs an audit of a GitLab instance's container registries.
# It iterates through all projects, their repositories, and image tags to
# gather detailed information about storage usage.

# Options:
#
#   -v (Verbose): When used with the terminal report, this option prints a
#                 detailed list of all image tags within each repository,
#                 distinguishing between unique and duplicate layers.
#
#   -x (CSV Export): This option bypasses the terminal report and instead
#                    generates a `registry_usage_report.csv` file in the
#                    current directory.
#
#
# Requirements:
#
# - `curl`: For making API requests to the GitLab instance.
# - `jq`: For parsing JSON responses from the GitLab API.
# - A GitLab Personal Access Token with `api` and `read_registry` scopes.
#
#
# Usage:
#
# 1.  Set the `TOKEN` and `GITLAB_URL` variables in the script.
# 2.  Make the script executable: `chmod +x your_script_name.sh`
# 3.  Run the script:
#     - For a standard terminal report: `./your_script_name.sh`
#     - For a verbose terminal report: `./your_script_name.sh -v`
#     - For a CSV export: `./your_script_name.sh -x`
#



TOKEN="....."
GITLAB_URL="https://registry/"


# --- Argument Parsing ---
VERBOSE=false
CSV_EXPORT=false
while getopts "vx" opt; do
  case ${opt} in
    v ) VERBOSE=true ;;
    x ) CSV_EXPORT=true ;;
    \? ) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# --- Initialization ---
if [ -z "$TOKEN" ]; then
    echo "🚨 Error: Please set the GITLAB_ADMIN_TOKEN environment variable."
    exit 1
fi
GITLAB_URL=${GITLAB_URL%/}

# Colors & Temp Files
COLOR_GREEN='\033[0;32m'
COLOR_GRAY='\033[0;90m'
COLOR_BOLD='\033[1m'
COLOR_STRIKE='\e[9m'
COLOR_NC='\033[0m'
RAW_DATA_FILE=$(mktemp)
SORTED_DATA_FILE=$(mktemp)
DEDUPED_DATA_FILE=$(mktemp)

# --- Stage 1: Data Collection ---
echo -e "${COLOR_BOLD}--- STAGE 1 of 4: Collecting data from all projects... ---${COLOR_NC}"
PAGE=1
while : ; do
    projects_json=$(curl --silent --show-error --fail --header "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects?owned=false&per_page=100&page=${PAGE}")
    if [ -z "$projects_json" ] || ! echo "$projects_json" | jq -e 'if type == "array" and length > 0 then true else false end' > /dev/null; then
        break
    fi

    echo "$projects_json" | jq -c '.[] | {id: .id, name: .path_with_namespace}' | while IFS= read -r project_info; do
        PROJECT_ID=$(echo "$project_info" | jq '.id')
        PROJECT_NAME=$(echo "$project_info" | jq -r '.name')

        printf "Scanning project: %-80s\r" "$PROJECT_NAME"

        repositories_json=$(curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
            "${GITLAB_URL}/api/v4/projects/$PROJECT_ID/registry/repositories?per_page=100")

        echo "$repositories_json" | jq -c '.[] | {id: .id, name: .name}' | while IFS= read -r repository_info; do
            repo_id=$(echo "$repository_info" | jq '.id')
            repo_name=$(echo "$repository_info" | jq -r '.name')

            tag_names=$(curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
                "${GITLAB_URL}/api/v4/projects/$PROJECT_ID/registry/repositories/$repo_id/tags?per_page=100" | jq -r '.[].name')

            if [ -n "$tag_names" ]; then
                for tag_name in $tag_names; do
                    tag_details=$(curl --silent --header "PRIVATE-TOKEN: $TOKEN" \
                        "${GITLAB_URL}/api/v4/projects/$PROJECT_ID/registry/repositories/$repo_id/tags/${tag_name}")

                    tag_size=$(echo "$tag_details" | jq '.total_size')
                    tag_created_at=$(echo "$tag_details" | jq -r '.created_at')
                    tag_digest=$(echo "$tag_details" | jq -r '.digest')
                    tag_location=$(echo "$tag_details" | jq -r '.location') # Get full image path

                    if [ -n "$tag_size" ] && [ "$tag_size" != "null" ] && [ -n "$tag_digest" ] && [ "$tag_digest" != "null" ]; then
                        # Raw data format: Project;Repo;Tag;Size;Digest;CreatedAt;Location
                        echo "${PROJECT_NAME};${repo_name};${tag_name};${tag_size};${tag_digest};${tag_created_at};${tag_location}" >> "$RAW_DATA_FILE"
                    fi
                done
            fi
        done
    done
    ((PAGE++))
done
printf "\n"
echo -e "${COLOR_GREEN}✔ Data collection complete.${COLOR_NC}"

# --- Stage 2: Sort Data by Date ---
echo -e "${COLOR_BOLD}--- STAGE 2 of 4: Sorting all tags by creation date... ---${COLOR_NC}"
sort -t';' -k6,6 "$RAW_DATA_FILE" > "$SORTED_DATA_FILE"
echo -e "${COLOR_GREEN}✔ Sorting complete.${COLOR_NC}"

# --- Stage 3: Global Deduplication ---
echo -e "${COLOR_BOLD}--- STAGE 3 of 4: Processing and deduplicating data... ---${COLOR_NC}"
# Output format: RawData...;Location;Status(unique/duplicate)
awk -F';' '{if(seen[$5]++){print $0 ";duplicate"} else {print $0 ";unique"}}' "$SORTED_DATA_FILE" > "$DEDUPED_DATA_FILE"
echo -e "${COLOR_GREEN}✔ Deduplication complete.${COLOR_NC}"


# --- Stage 4: Report Generation or CSV Export ---
if [ "$CSV_EXPORT" = true ]; then
    echo -e "${COLOR_BOLD}--- STAGE 4 of 4: Generating CSV report... ---${COLOR_NC}"
    CSV_FILE="registry_usage_report.csv"

    # CSV Header
    echo "PROJECT;REGISTRY;REAL_USAGE_CONTRIBUTION_BYTES;DATE;SHA256;VIRTUAL_USAGE_BYTES;IS_DUPLICATE;FULL_IMAGE_PATH" > "$CSV_FILE"

    # CSV Body
    awk -F';' '
        BEGIN { OFS=";" }
        {
            project=$1;
            registry=$2;
            virtual_usage=$4;
            sha256=$5;
            date=$6;
            full_path=$7;
            status=$8;

            is_duplicate = (status=="unique" ? "N" : "Y");
            real_usage = (status=="unique" ? virtual_usage : "0");

            print project, registry, real_usage, date, sha256, virtual_usage, is_duplicate, full_path;
        }
    ' "$DEDUPED_DATA_FILE" >> "$CSV_FILE"

    echo -e "${COLOR_GREEN}✔ CSV report '${CSV_FILE}' created successfully.${COLOR_NC}"

else # Standard Terminal Report
    echo -e "${COLOR_BOLD}--- STAGE 4 of 4: Generating terminal report... ---${COLOR_NC}"
    if [ "$VERBOSE" = true ]; then
      echo "(Verbose mode enabled: showing all tag details)"
    fi



    format_size() {
        local bytes=$1
        if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then echo "0 B"; return; fi
        awk -v b=$bytes 'BEGIN{s="B K M G T P"; split(s,a); while(b>=1024 && length(s)>1){b/=1024; s=substr(s,3)} printf "%.2f %s", b, substr(s,1,1)}'
    }

    VIRTUAL_GRAND_TOTAL=$(awk -F';' '{s+=$4} END {print s}' "$RAW_DATA_FILE")
    REAL_GRAND_TOTAL=$(awk -F';' '$8=="unique"{s+=$4} END {print s}' "$DEDUPED_DATA_FILE")

    echo "======================================================================"
    echo -e "          ${COLOR_BOLD}Container Registry - Total Usage Summary${COLOR_NC}"
    echo -e "   ${COLOR_BOLD}Total Real Size (Deduplicated): $(format_size "$REAL_GRAND_TOTAL")${COLOR_NC}"
    echo -e "   ${COLOR_BOLD}Total Virtual Size (Inflated): $(format_size "$VIRTUAL_GRAND_TOTAL")${COLOR_NC}"
    echo "======================================================================"

    sort -t';' -u -k1,1 "$DEDUPED_DATA_FILE" | cut -d';' -f1 | while read -r project_name; do

        PROJECT_VIRTUAL_SIZE=$(grep "^${project_name};" "$RAW_DATA_FILE" | awk -F';' '{s+=$4} END {print s}')
        PROJECT_REAL_SIZE=$(grep "^${project_name};" "$DEDUPED_DATA_FILE" | awk -F';' '$8=="unique"{s+=$4} END {print s}')

        echo -e "\n${COLOR_BOLD}Project: ${project_name}${COLOR_NC}"
        echo "  Real Usage (Deduplicated): $(format_size "$PROJECT_REAL_SIZE")"
        echo "  Virtual Usage (Inflated): $(format_size "$PROJECT_VIRTUAL_SIZE")"

        grep "^${project_name};" "$DEDUPED_DATA_FILE" | sort -t';' -u -k2,2 | cut -d';' -f2 | while read -r repo_name; do

            REPO_VIRTUAL_SIZE=$(grep "^${project_name};${repo_name};" "$RAW_DATA_FILE" | awk -F';' '{s+=$4} END {print s}')
            REPO_REAL_SIZE=$(grep "^${project_name};${repo_name};" "$DEDUPED_DATA_FILE" | awk -F';' '$8=="unique"{s+=$4} END {print s}')

            echo "  ├── Repository: ${repo_name} | Real: $(format_size "$REPO_REAL_SIZE") | Virtual: $(format_size "$REPO_VIRTUAL_SIZE")"

            if [ "$VERBOSE" = true ]; then
                grep "^${project_name};${repo_name};" "$DEDUPED_DATA_FILE" | sort -t';' -k4,4rn | while IFS= read -r line; do
                    tag_name=$(echo "$line" | cut -d';' -f3)
                    original_size=$(echo "$line" | cut -d';' -f4)
                    tag_digest=$(echo "$line" | cut -d';' -f5)
                    tag_created_at=$(echo "$line" | cut -d';' -f6)
                    tag_location=$(echo "$line" | cut -d';' -f7)
                    status=$(echo "$line" | cut -d';' -f8)

                    formatted_date=$(echo "$tag_created_at" | cut -dT -f1)
                    formatted_tag_size=$(format_size "$original_size")

                    if [ "$status" == "duplicate" ]; then
                        COLOR="$COLOR_GRAY$COLOR_STRIKE"
                        SIZE_INFO="(duplicate of ${formatted_tag_size})"
                    else
                        COLOR=$COLOR_GREEN
                        SIZE_INFO="${formatted_tag_size}"
                    fi

                    echo -e "  │   └── ${COLOR}Tag: ${tag_name} (Size: ${SIZE_INFO}, Created: ${formatted_date})${COLOR_NC}"
                    echo -e "  │       ${COLOR_GRAY}└─ Path: ${tag_location}${COLOR_NC}"
                    echo -e "  │       ${COLOR_GRAY}   Digest: ${tag_digest}${COLOR_NC}"
                done
            fi
        done
        echo "----------------------------------------------------------------------"
    done
fi

# --- Cleanup ---
rm "$RAW_DATA_FILE" "$SORTED_DATA_FILE" "$DEDUPED_DATA_FILE"
echo -e "\n✅ Report complete."


