![Header](.mdfiles/Header.webp)



# Toolbox

Custom scripts for linux sysadmins 

[!TIP]
Generally, those scripts are designed only for presentation purposes and do not make any changes to the operating system.



## List of Scripts

- **ansible_apt_updateupgrade.yml**
  - An Ansible playbook that updates and upgrades all packages on Ubuntu hosts using `apt`, with a one-hour cache validity.
  - Checks for a required reboot and performs it if necessary, ensuring the system is stable post-upgrade with uptime and kernel version checks.

- **ansible_s1_check_versions.yml**
  - An Ansible playbook that checks the version of the SentinelOne agent on target hosts by querying the `sentinelctl` binary.
  - Outputs the hostname and version details, or "NONE" if the agent is not installed, for easy monitoring of deployment status.

- **ansible_s1_install_deb.yml**
  - An Ansible playbook that installs or upgrades the SentinelOne Linux agent on Debian-based systems using the latest `.deb` package from a local directory.
  - Applies a registration token, starts the agent, and cleans up temporary files, ensuring system stability with pre-installation checks.

- **count_files_by_date.sh**
  - Scans a specified directory to report the number of files created each day over the last 180 days, with optional size and percentage usage details.
  - Supports flags to customize the target directory and display file sizes in MB, aiding in disk usage analysis.

- **denied-named-list.sh**
  - Analyzes `named` service logs to extract IP addresses associated with denied DNS queries, counting occurrences and resolving IPs to domains.
  - Outputs a sorted table with counts, IPs, and domain names (or "(none)" if unresolved), useful for identifying suspicious DNS activity.

- **dns_live.go**
  - A Go program that monitors DNS records (NS, SOA, A, MX, TXT, etc.) for specified domains, displaying results in a real-time interactive table.
  - It tracks changes with a history log and highlights recent updates using a blinking effect for easy monitoring.

- **docker_images_inspector.sh**
  - Generates reports (`images-in-use.txt` and `images-unused.txt`) listing Docker images, identifying those used by containers or as parents and those safe to delete.
  - Requires Bash 4+ and sudo access to Docker for inspecting images and their dependencies.

- **docker_volumes_backup.sh**
  - Creates compressed tar.gz backups of all Docker volumes in a specified directory with timestamps for easy versioning.
  - Uses an Alpine Docker container to perform the backup, ensuring minimal dependencies and clean execution.

- **docker_volumes_restore.sh**
  - Restores Docker volumes from tar.gz backup files in a specified directory, recreating volumes if they don’t exist.
  - Utilizes an Alpine Docker container to extract backups, ensuring compatibility and simplicity.

- **network_info_table**
  - Parses `lshw -class network` output to display a formatted table of network device details, including Physical ID, Product, Bus info, Size, and Capacity.
  - Designed for quick reference, it helps sysadmins inspect network hardware configurations without manual parsing.

- **nofile-by-limit.sh**
  - Displays a table of active processes with their open file descriptors, FD limits, and usage percentages, with optional verbose mode for GID, SID, CPU, and RSS.
  - Supports sorting by open file descriptors and color-coded output to highlight high FD usage for system monitoring.

- **nofile-by-session.sh**
  - Reports open file descriptors, usernames, PIDs, FD limits, and commands for each active Linux session, helping monitor resource usage per session.
  - Features color-coded output based on FD limit percentages and suggests `prlimit` for adjusting limits if needed.

- **tcp_retransmissions_synch.sh**
  - Captures and analyzes TCP SYN packets or all TCP retransmissions on a specified network interface, reporting counts and details with percentages.
  - Supports options for duration, file size, and IP resolution, with color-coded output for high retransmission rates.

- **vim_bash_ide3.sh**
  - Configures Vim as a Bash script IDE by installing dependencies like `coc.nvim`, `NERDTree`, `Tagbar`, and `ALE` for linting and formatting.
  - Includes Gitleaks integration and sensitive data detection to enhance security during script development.
- **gitlab_registry_images_audit.sh*
  - This script performs an audit of a GitLab instance's container registries.
       
- count_files_by_days.sh This Bash script scans a specified directory and reports the number of files created on each of the last 180 days.
  **Usage:**
  ```bash
        $0 [-p <target_dir>] [-s] [-sd]
        * `-p <target_dir>` (optional): Specifies the target directory to scan. Defaults to " /home/webdocuments/1/99315/attachments".
        * `-s`: Displays the total size (in MB) of files for each day (requires `-sd`).
        * `-sd`: Calculates and displays the total size and percentage usage of the directory for each d  ay.
```
