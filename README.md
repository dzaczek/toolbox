![Header](.mdfiles/Header.webp)



# Toolbox

Custom scripts for linux sysadmins 

[!TIP]
Generally, those scripts are designed only for presentation purposes and do not make any changes to the operating system.

List scripts: 
- "[nofile-by-session.sh](nofile-by-session.sh)" -  each active session(sid) on a Linux system and amount number of files open by session (ps remmber limits nofile are for the pids not for session) .
- "[nofile-by-limit.sh](nofile-by-limit.sh)" - each active processv + amount of filedescriptors + limit  for this on pid
- "[tcp_retransmissions_synch.sh](tcp_retransmissions_synch.sh)" - count TCP SYN Retransmits and with -a all Retransmits 

- count_files_by_days.sh This Bash script scans a specified directory and reports the number of files created on each of the last 180 days.
  **Usage:**
  ```bash
        $0 [-p <target_dir>] [-s] [-sd]
        * `-p <target_dir>` (optional): Specifies the target directory to scan. Defaults to " /home/webdocuments/1/99315/attachments".
        * `-s`: Displays the total size (in MB) of files for each day (requires `-sd`).
        * `-sd`: Calculates and displays the total size and percentage usage of the directory for each d  ay.
```
