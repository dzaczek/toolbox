#!/bin/bash
#Kill other souls conned as pts/* 

MY_TTY=$(who am i | awk '{print $2}')
MY_PID=$$
# list all ssh/pts sessions except current one
for TTY in $(who | awk '{print $2}' | grep pts/ | sort -u); do
    if [ "$TTY" != "$MY_TTY" ]; then
        echo "Logging out users on $TTY"
        
        pkill -KILL -t $TTY
    fi
done
