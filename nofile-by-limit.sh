#!/bin/bash

# Column width definitions
pid_col_width=10
fd_col_width=20
limit_col_width=15
percent_col_width=10
cmd_col_width=50
extra_col_width=10  # For GID, SID, %CPU, RSS

# Option flags
verbose=0
sort_output=0

# Parse command-line options
while getopts "vs" opt; do
    case $opt in
        v) verbose=1 ;;
        s) sort_output=1 ;;
        *) echo "Usage: $0 [-v (verbose)] [-s (sort)]"; exit 1 ;;
    esac
done

# ANSI color codes
YELLOW='\033[1;33m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print table header
header_format="%-${pid_col_width}s %-${fd_col_width}s %-${limit_col_width}s %-${percent_col_width}s %-${cmd_col_width}s"
header_content=("PID" "Open FDs" "FD Limit" "Percentage" "Command")
if [ $verbose -eq 1 ]; then
    header_format+=" %-${extra_col_width}s %-${extra_col_width}s %-${extra_col_width}s %-${extra_col_width}s\n"
    header_content+=("GID" "SID" "%CPU" "RSS")
else
    header_format+="\n"
fi
printf "$header_format" "${header_content[@]}"
printf "$header_format" "${header_content[@]//?/-}"

# Initialize an array to hold each line of output
declare -a output_lines

# Get all PIDs
pids=$(ls -l /proc | grep '^d' | awk '{print $9}' | grep '^[0-9]' | sort -n)

# Loop through each PID
for pid in $pids; do
    # Check if /proc/[pid] exists (process might have ended)
    if [ ! -d "/proc/$pid" ]; then
        continue
    fi

    # Get the number of file descriptors for this PID
    fd_count=$(ls /proc/$pid/fd 2>/dev/null | wc -l)

    # Get the file descriptor limit for this PID
    fd_limit=$(grep "Max open files" /proc/$pid/limits 2>/dev/null | awk '{print $4}')

    # Get the command name from /proc/[pid]/comm
    cmd=$(cat /proc/$pid/comm 2>/dev/null | cut -c 1-50)

    # Only get GID, SID, %CPU, and RSS if verbose flag is set
    gid=""
    sid=""
    cpu=""
    rss=""
    if [ $verbose -eq 1 ]; then
        if [ -d "/proc/$pid" ]; then
            gid=$(ps -o gid= -p $pid)
            sid=$(ps -o sid= -p $pid)
            cpu=$(ps -o %cpu= -p $pid)
            rss=$(ps -o rss= -p $pid)
        fi
    fi

    # Calculate the percentage of FD limit used
    percentage=0
    if [ -n "$fd_limit" ] && [ "$fd_limit" -ne 0 ]; then
        percentage=$((fd_count * 100 / fd_limit))
    fi

    # Set the color based on the percentage used
    color=$NC
    if [ "$percentage" -gt 80 ]; then
        color=$RED
    elif [ "$percentage" -gt 50 ]; then
        color=$ORANGE
    elif [ "$percentage" -gt 20 ]; then
        color=$YELLOW
    fi

    # Construct the output line
    line_format="%-${pid_col_width}s %-${fd_col_width}s %-${limit_col_width}s %-${percent_col_width}s %-${cmd_col_width}s"
    if [ $verbose -eq 1 ]; then
        line_format+=" %-${extra_col_width}s %-${extra_col_width}s %-${extra_col_width}s %-${extra_col_width}s\n"
        output_line=$(printf "${color}$line_format${NC}" "$pid" "$fd_count" "$fd_limit" "$percentage%" "$cmd" "$gid" "$sid" "$cpu" "$rss")
    else
        line_format+="\n"
        output_line=$(printf "${color}$line_format${NC}" "$pid" "$fd_count" "$fd_limit" "$percentage%" "$cmd")
    fi

    # Add the line to the array
    output_lines+=("$output_line")
done

# Output the results
if [ $sort_output -eq 1 ]; then
    # Sort by the number of open file descriptors (second column)
    printf "%s\n" "${output_lines[@]}" | sort -k2 -n -r
else
    # No sorting, just output
    printf "%s\n" "${output_lines[@]}"
fi


