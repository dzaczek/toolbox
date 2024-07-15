#!/bin/bash

# Default values
INTERFACE="eth0"
DURATION=60
FILESIZE=200  # Default file size in MB
RESOLVE_IPS=false
ALL_RETRANSMISSIONS=false

# Function to print help message
print_help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -i INTERFACE  Specify the network interface (default: eth0)"
  echo "  -t DURATION   Specify the duration of the capture in seconds (default: 60)"
  echo "  -c FILESIZE   Specify the file size limit for the tcpdump in MB (default: 200)"
  echo "  -d            Resolve IP addresses to domain names"
  echo "  -a            Capture only TCP retransmissions"
  echo "  -h            Show this help message"
}

# Function to check if the script is already running
check_if_running() {
  # Use pidof to check if another instance of this script is running.
  # -o %PPID excludes the parent process ID
  # -x specifies the script name to check if it is running
  if pidof -o %PPID -x "$(basename "$0")" > /dev/null; then
    echo "The script is already running."
    exit 1
  fi
}

# Function to check required packages
check_required_packages() {
  # List of required packages
  local packages=("tcpdump" "tshark" "awk" "bc" "timeout")
  # Loop through each package and check if it is installed
  for package in "${packages[@]}"; do
    if ! command -v $package &> /dev/null; then
      echo "Error: $package is not installed."
      exit 1
    fi
  done
}

# Check if the script is already running
check_if_running

# Check required packages
check_required_packages

# Parse command line arguments
while getopts "i:t:c:daH" opt; do
  case $opt in
    i) INTERFACE=$OPTARG ;;  # Set the network interface
    t) DURATION=$OPTARG ;;   # Set the duration of packet capture
    c) FILESIZE=$OPTARG ;;   # Set the file size limit for tcpdump
    d) RESOLVE_IPS=true ;;   # Enable resolving IP addresses to domain names
    a) ALL_RETRANSMISSIONS=true ;; # Capture only TCP retransmissions
    h) print_help; exit 0 ;; # Print help message and exit
    *) print_help; exit 1 ;; # Print help message and exit on invalid argument
  esac
done

# Ensure FILESIZE is a number
if ! [[ $FILESIZE =~ ^[0-9]+$ ]]; then
  echo "Error: FILESIZE must be a number."
  exit 1
fi

# Remove the syn_packets.pcap file if it exists
if [ -f syn_packets.pcap ]; then
  echo "Removing existing syn_packets.pcap file..."
  rm syn_packets.pcap
fi

echo "Capturing TCP packets for $DURATION seconds on interface $INTERFACE with file size limit ${FILESIZE}MB..."

# Determine the tcpdump filter based on whether all retransmissions are being captured
if $ALL_RETRANSMISSIONS; then
#       TCPDUMP_FILTER='(tcp[tcpflags] & (tcp-ack != 0)) & (tcp[tcpflags] & (tcp-syn) == 0)'
        TCPDUMP_FILTER='tcp[tcpflags] & 0x10 != 0 and tcp[tcpflags] & 0x02 == 0'
else
        TCPDUMP_FILTER='tcp[tcpflags] & (tcp-syn) != 0'
fi

# Capture packets with tcpdump using timeout to enforce duration limit
# -i $INTERFACE: use specified network interface
# $TCPDUMP_FILTER: filter for TCP packets based on selected option
# -w syn_packets.pcap: write captured packets to file
# -G $DURATION: set duration for the capture
# -W 1: limit to one file
# -C $FILESIZE: set maximum file size in MB
sudo timeout $DURATION tcpdump -i $INTERFACE "$TCPDUMP_FILTER" -w syn_packets.pcap -W 1 -C $FILESIZE
# hidden stamp hehe :D github.com/dzaczek/toolbox:x

echo "Analyzing captured packets..."
if $RESOLVE_IPS; then
  # Analyze captured packets with tshark and resolve IP addresses to domain names
  tshark -r syn_packets.pcap -T fields -e ip.src -e ip.dst -e tcp.seq -e ip.src_resolved -e ip.dst_resolved > syn_packets.txt
else
  # Analyze captured packets with tshark without resolving IP addresses
  tshark -r syn_packets.pcap -T fields -e ip.src -e ip.dst -e tcp.seq > syn_packets.txt
fi

echo "Counting retransmissions..."
if $ALL_RETRANSMISSIONS; then
  # Count retransmissions by sorting and finding duplicate sequence numbers in syn_packets.txt
  RETRANSMISSIONS=$(sort syn_packets.txt | uniq -c | awk '$1 > 1 {sum += $1} END {print sum}')
  # Extract IPs with retransmissions and count per connection, aggregating counts for unique connections
  RETRANSMISSION_DETAILS=$(sort syn_packets.txt | uniq -c | awk '$1 > 1 {count[$2 " " $3] += $1} END {for (pair in count) print count[pair], pair}')
else
  # Count SYN retransmissions by sorting and counting unique occurrences in syn_packets.txt
  RETRANSMISSIONS=$(sort syn_packets.txt | uniq -c | awk '$1 > 1 {sum += $1} END {print sum}')
  # Extract IPs with retransmissions and count per connection, aggregating counts for unique connections
  RETRANSMISSION_DETAILS=$(sort syn_packets.txt | uniq -c | awk '$1 > 1 {count[$2 " " $3] += $1} END {for (pair in count) print count[pair], pair}')
fi

# Check if RETRANSMISSIONS is set and is a valid number
if [[ -z "$RETRANSMISSIONS" || ! "$RETRANSMISSIONS" =~ ^[0-9]+$ ]]; then
  echo "Error: Failed to count retransmissions or invalid retransmission count."
  exit 1
fi

# Colorize output: red for maximum retransmissions
echo -e "\033[1;31m$RETRANSMISSIONS retransmissions\033[0m"
echo -e "Details of retransmissions (Count, Source IP, Destination IP, Percentage):\n"

# Calculate the percentage for each retransmission count and print details with color coding
echo "$RETRANSMISSION_DETAILS" | sort -k 1 -n | while read count src dst; do
  percentage=$(echo "scale=2; ($count / $RETRANSMISSIONS) * 100" | bc)
  if (( $(echo "$percentage >= 30" | bc -l) )); then
    echo -e "\033[1;31m$count $src $dst ($percentage%)\033[0m" # Red for >= 30%
  elif (( $(echo "$percentage >= 20" | bc -l) )); then
    echo -e "\033[0;33m$count $src $dst ($percentage%)\033[0m" # Orange for >= 20%
  elif (( $(echo "$percentage >= 10" | bc -l) )); then
    echo -e "\033[1;33m$count $src $dst ($percentage%)\033[0m" # Yellow for >= 10%
  else
    echo "$count $src $dst ($percentage%)" # No color for < 10%
  fi
done

echo "Rate calculation (retransmissions per minute)..."
# Calculate the rate of retransmissions per minute
RATE=$(echo "scale=2; $RETRANSMISSIONS / ($DURATION / 60)" | bc -l)
if [[ $? -ne 0 ]]; then
  echo "Error: Rate calculation failed."
  exit 1
fi
echo -e "Rate of TCP Retransmits OUT: \033[1;31m$RATE\033[0m per minute"
