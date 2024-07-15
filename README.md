![Header](.mdfiles/Header.webp)



# Toolbox

Custom scripts for linux sysadmins 

[!TIP]
Generally, those scripts are designed only for presentation purposes and do not make any changes to the operating system.

List scripts: 
- "[nofile-by-session.sh](nofile-by-session.sh)" -  each active session(sid) on a Linux system and amount number of files open by session (ps remmber limits nofile are for the pids not for session) .
- "[nofile-by-limit.sh](nofile-by-limit.sh)" - each active processv + amount of filedescriptors + limit  for this on pid
- "[tcp_retransmissions_synch.sh](tcp_retransmissions_synch.sh)" - count TCP SYN Retransmits and with -a all Retransmits 
