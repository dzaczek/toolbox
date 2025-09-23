#!/bin/bash

for i in $(ceph osd ls); do
  ceph daemon osd.$i perf dump 2>/dev/null | jq -r --arg i "$i" '
    def n: tonumber? // 0;
    def find($k): [.. | objects | select(has($k)) | .[$k]] | first;
    (find("db_used_bytes")  | n) as $du |
    (find("db_total_bytes") | n) as $dt |
    (find("wal_used_bytes") | n) as $wu |
    (find("wal_total_bytes")| n) as $wt |
    "osd.\($i)  db=\( ($du/1073741824|floor) )/\( ($dt/1073741824|floor) )GiB  " +
    "db_pct=\( if $dt>0 then ($du*100/$dt|floor) else "NA" end )%  " +
    "wal=\( ($wu/1073741824|floor) )/\( ($wt/1073741824|floor) )GiB"
  '
done
