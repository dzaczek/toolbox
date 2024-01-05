#!/bin/bash
#  This script provides detailed information about each active
#  session on a Linux system. It displays various metrics such as 
#  the number of open file descriptors, the usernames associated 
#  with each session, a list of process IDs (PIDs) within each session,
#  the limit of open files, and the commands being executed by these processes.
#
#  For change pid  nofile limit 
#  prlimit --pid <pid> --nofile=11000:50000
#
#  


# ANSI color codes
YELLOW='\033[1;33m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print table header
printf "%-10s %-20s %-15s %-40s %-15s %-10s %-50s\n" "SessionID" "Open Files" "Username" "PIDs in Session" "FD Limit" "Percentage" "Commands"
printf "%-10s %-20s %-15s %-40s %-15s %-10s %-50s\n" "---------" "----------" "--------" "---------------" "--------" "----------" "--------"

# Get a list of unique session IDs
sessions=$(ps -eo sid | grep -v "SID" | sort -n | uniq)

# Loop through each session
for sid in $sessions; do
    # Skip if session ID is -1 or 0 (kernel processes)
    if [ "$sid" == "-1" ] || [ "$sid" == "0" ]; then
        continue
    fi

    # Initialize total file descriptor count, PID list, and username for this session
    total_fd=0
    pid_list=""
    username=""
    fd_limit=""
    cmd_list=""
    color=$NC

    # Get all PIDs, their usernames, commands, and the session leader PID for the current session
    pids_users_cmds=$(ps -eo sid,pid,user,cmd | awk -v sid="$sid" '$1 == sid { print $2 ":" $3 ":" $4 }')
    session_leader=$(ps -eo sid,pid | awk -v sid="$sid" '$1 == sid { print $2 }' | head -n 1)
    
    for puc in $pids_users_cmds; do
        pid=${puc%%:*}
        remaining=${puc#*:}
        user=${remaining%%:*}
        cmd=${remaining#*:}

        # Count the number of file descriptors for this PID
        fd_count=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
        total_fd=$((total_fd + fd_count))

        # Append the PID to the pid_list
        pid_list+="$pid,"

        # Append the command to the cmd_list
        cmd_list+="${cmd:0:30}...," # Truncate command for display

        # Set the username (assuming all PIDs in the session have the same user)
        if [ -z "$username" ]; then
            username=$user
        fi
    done

    # Remove the trailing commas from the pid_list and cmd_list
    pid_list=${pid_list%,}
    cmd_list=${cmd_list%,}

    # Get the file descriptor limit from /proc/[session_leader]/limits
    if [ -n "$session_leader" ]; then
        fd_limit=$(grep "Max open files" /proc/$session_leader/limits | awk '{print $4}')
    fi

    # Calculate the percentage of FD limit used
    if [ -n "$fd_limit" ] && [ "$fd_limit" -ne 0 ]; then
        percentage=$((total_fd * 100 / fd_limit))
    else
        percentage=0
    fi

    # Set the color based on the percentage used
    if [ "$percentage" -gt 80 ]; then
        color=$RED
    elif [ "$percentage" -gt 50 ]; then
        color=$ORANGE
    elif [ "$percentage" -gt 20 ]; then
        color=$YELLOW
    fi

    # Display the session ID, total open files, username, list of PIDs, file descriptor limit, percentage, and commands for the session with color
    printf "${color}%-10s %-20s %-15s %-40s %-15s %-10s %-50s${NC}\n" "$sid" "$total_fd" "$username" "$pid_list" "$fd_limit" "$percentage%" "$cmd_list"
done
