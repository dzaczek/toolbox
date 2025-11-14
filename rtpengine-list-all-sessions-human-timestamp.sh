rtpengine-ctl get sessions all | sort -t'|' -k3,3n | awk -F'|' '{
    if ($3 ~ /creat:/) {
        ts=$3
        sub("creat:","",ts)
        gsub(" ","",ts)
        cmd="date -d @"ts" +\"%Y-%m-%d %H:%M:%S\""
        cmd | getline h
        close(cmd)
        print h " | " $0
    }
}'
