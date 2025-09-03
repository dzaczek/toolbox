#!/bin/bash

printf "%-15s | %-8s\n" "Interface" "MTU"
printf "%-15s-+-%-8s\n" "---------------" "--------"

for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    mtu=$(cat "$iface/mtu" 2>/dev/null)
    printf "%-15s | %-8s\n" "$name" "$mtu"
done
