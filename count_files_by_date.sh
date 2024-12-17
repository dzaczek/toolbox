#!/bin/bash
#dzaczek
# Default target directory
DEFAULT_TARGET_DIR="/home/"

# Initialize flags and variables
TARGET_DIR="$DEFAULT_TARGET_DIR"
SHOW_SIZE=false
SHOW_SIZE_DETAIL=false

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)
            shift
            TARGET_DIR="$1"
            # Check if the directory exists
            if [ ! -d "$TARGET_DIR" ]; then
                echo "Error: Directory '$TARGET_DIR' does not exist."
                exit 1
            fi
            ;;
        -s)
            SHOW_SIZE=true
            ;;
        -sd)
            SHOW_SIZE=true
            SHOW_SIZE_DETAIL=true
            ;;
        *)
            echo "Usage: $0 [-p <target_dir>] [-s] [-sd]"
            exit 1
            ;;
    esac
    shift
done

# Days to look back
DAYS=180

# Calculate the total size of the directory if -sd is enabled
if [ "$SHOW_SIZE_DETAIL" = true ]; then
    TOTAL_DIR_SIZE=$(du -sb "$TARGET_DIR" | awk '{print $1}') # Total size in bytes
    TOTAL_DIR_SIZE_MB=$(awk "BEGIN {print $TOTAL_DIR_SIZE / 1024 / 1024}") # Convert to MB
fi

# Output header
echo "Scanning directory: $TARGET_DIR"

if [ "$SHOW_SIZE_DETAIL" = true ]; then
    echo "Date       | File Count | Total Size (MB) | % Usage"
    echo "-----------|------------|-----------------|---------"
elif [ "$SHOW_SIZE" = true ]; then
    echo "Date       | File Count | Total Size (MB)"
    echo "-----------|------------|-----------------"
else
    echo "Date       | File Count"
    echo "-----------|------------"
fi

# Loop through the last 180 days
for i in $(seq 0 $DAYS); do
    # Calculate the date (today - i days)
    DATE=$(date -d "-$i days" +%Y-%m-%d)

    if [ "$SHOW_SIZE" = true ]; then
        # Find files created on this specific day and calculate size
        OUTPUT=$(find "$TARGET_DIR" -type f -newermt "$DATE 00:00:00" ! -newermt "$DATE 23:59:59" -printf "%s\n")
        COUNT=$(echo "$OUTPUT" | wc -l)
        SIZE=$(echo "$OUTPUT" | awk '{sum += $1} END {print sum / 1024 / 1024}') # Size in MB
        SIZE=${SIZE:-0} # Default to 0 if no size

        if [ "$SHOW_SIZE_DETAIL" = true ]; then
            # Calculate percentage usage
            PERCENTAGE=$(awk "BEGIN {if ($TOTAL_DIR_SIZE_MB > 0) print ($SIZE / $TOTAL_DIR_SIZE_MB) * 100; else print 0}")
            printf "%-10s | %-10s | %-15s | %.2f%%\n" "$DATE" "$COUNT" "$SIZE" "$PERCENTAGE"
        else
            printf "%-10s | %-10s | %-15s\n" "$DATE" "$COUNT" "$SIZE"
        fi
    else
        # Find files without size details
        COUNT=$(find "$TARGET_DIR" -type f -newermt "$DATE 00:00:00" ! -newermt "$DATE 23:59:59" | wc -l)
        printf "%-10s | %-10s\n" "$DATE" "$COUNT"
    fi
done
