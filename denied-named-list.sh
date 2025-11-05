#!/bin/bash
#dns
journalctl -u named | grep denied |grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -nr | while read count ip; do

    domain=$(dig -x $ip +short | tr "\n" " ")
    if [ -z "$domain" ]; then
        domain="(none )"
    fi
    printf "%-10s %-15s %s\n" "$count" "$ip" "$domain"
done
