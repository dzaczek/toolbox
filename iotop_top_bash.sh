#!/usr/bin/env bash
printf "%-8s %-20s %12s %12s %12s %12s\n" "PID" "COMMAND" "RCHAR" "WCHAR" "RBYTES" "WBYTES"

for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  if [ -r /proc/$pid/io ]; then
    cmd=$(cat /proc/$pid/comm 2>/dev/null)
    rchar=$(awk '/rchar:/ {print $2}' /proc/$pid/io)
    wchar=$(awk '/wchar:/ {print $2}' /proc/$pid/io)
    rbytes=$(awk '/read_bytes:/ {print $2}' /proc/$pid/io)
    wbytes=$(awk '/write_bytes:/ {print $2}' /proc/$pid/io)
    printf "%-8s %-20s %12s %12s %12s %12s\n" "$pid" "$cmd" "$rchar" "$wchar" "$rbytes" "$wbytes"
  fi
done | sort -k5 -n -r | head -20
