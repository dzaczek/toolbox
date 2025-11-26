#!/usr/bin/perl
# ==============================================================================
# PLUGIN: check_opensearch_pure.pl
# 
# DESCRIPTION:
#   This is a lightweight, "Pure Perl" monitoring plugin for OpenSearch (and Elasticsearch).
#   It is designed to check the health status of a cluster without requiring 
#   external Perl modules (like CPAN JSON or LWP::UserAgent), which are often 
#   missing on minimal server installations.
#
# HOW IT WORKS:
#   1. Arguments: Accepts Host, Port, Auth credentials, and Thresholds via CLI.
#   2. Execution: Uses the system 'curl' binary to query the OpenSearch API:
#      - /_cluster/health (for Status, Node Count, Unassigned Shards)
#      - /_nodes/stats (for JVM Heap usage and Thread rejections)
#   3. Parsing: Uses Perl Regex to extract values from the JSON output (dependency-free).
#   4. Logic: Compares stats against thresholds and returns standard Nagios codes:
#      - Exit 0: OK (Green)
#      - Exit 1: WARNING (Yellow or High Heap)
#      - Exit 2: CRITICAL (Red, Missing Nodes, or Very High Heap)
#
# USAGE EXAMPLE:
#   ./check_opensearch_pure.pl -H localhost -P 9200 -u admin -p mypass --ssl --insecure
#
# ==============================================================================

use strict;
use warnings;
use Getopt::Long;

# --- DEFAULTS ---
my $host = "localhost";
my $port = 9200;
my $user = "";
my $pass = "";
my $ssl  = 0;  # 0=http, 1=https
my $insecure = 0; # 1=ignore certs
my $crit_heap = 90;
my $warn_heap = 75;
my $expected_nodes = 0; # 0 = disabled

# --- PARSE ARGS ---
GetOptions(
    "H|host=s" => \$host,
    "P|port=i" => \$port,
    "u|user=s" => \$user,
    "p|password=s" => \$pass,
    "S|ssl" => \$ssl,
    "k|insecure" => \$insecure,
    "heap-crit=i" => \$crit_heap,
    "heap-warn=i" => \$warn_heap,
    "nodes=i" => \$expected_nodes,
);

# --- PREPARE CURL ---
my $proto = $ssl ? "https" : "http";
my $auth_cmd = ($user ne "") ? "-u \"$user:$pass\"" : "";
my $k_flag = $insecure ? "-k" : "";
my $base_cmd = "curl -s -m 10 $k_flag $auth_cmd";

# --- 1. CHECK CLUSTER HEALTH ---
my $health_url = "$proto://$host:$port/_cluster/health";
my $health_json = `$base_cmd "$health_url"`;

if ($? != 0 || !$health_json) {
    print "CRITICAL - Could not connect to OpenSearch at $host:$port (Check curl/network)\n";
    exit 2;
}

# Parse Health Regex
my ($status) = $health_json =~ /"status"\s*:\s*"(\w+)"/;
my ($node_count) = $health_json =~ /"number_of_nodes"\s*:\s*(\d+)/;
my ($unassigned) = $health_json =~ /"unassigned_shards"\s*:\s*(\d+)/;

$status //= "unknown";
$node_count //= 0;
$unassigned //= 0;

# --- 2. CHECK NODES STATS (Heap, Threads, FD) ---
# We fetch specific stats to keep response small
my $stats_url = "$proto://$host:$port/_nodes/stats/jvm,process,thread_pool";
my $stats_json = `$base_cmd "$stats_url"`;

# Parse Max Heap Used %
my $max_heap_found = 0;
while ($stats_json =~ /"heap_used_percent"\s*:\s*(\d+)/g) {
    if ($1 > $max_heap_found) { $max_heap_found = $1; }
}

# Parse Total Thread Rejections (Search + Write)
my $total_rejected = 0;
while ($stats_json =~ /"rejected"\s*:\s*(\d+)/g) {
    $total_rejected += $1;
}

# --- LOGIC & OUTPUT ---
my $msg = "Nodes: $node_count, Max Heap: $max_heap_found%, Unassigned: $unassigned, Rejected: $total_rejected";
my $perf = "| nodes=$node_count;;$expected_nodes heap_max=$max_heap_found%;$warn_heap;$crit_heap unassigned=$unassigned rejected=$total_rejected";

# Logic: Critical path first
if ($status eq "red") {
    print "CRITICAL - Cluster RED (Data Missing). $msg $perf\n";
    exit 2;
}
if ($max_heap_found >= $crit_heap) {
    print "CRITICAL - Heap usage high ($max_heap_found% > $crit_heap%). Node crash imminent! $perf\n";
    exit 2;
}
if ($expected_nodes > 0 && $node_count < $expected_nodes) {
    print "CRITICAL - Split Brain? Expected $expected_nodes nodes, found $node_count. $perf\n";
    exit 2;
}

# Warning path
if ($status eq "yellow") {
    print "WARNING - Cluster YELLOW. $msg $perf\n";
    exit 1;
}
if ($max_heap_found >= $warn_heap) {
    print "WARNING - Heap usage elevated ($max_heap_found%). $perf\n";
    exit 1;
}

# OK path
print "OK - Cluster Green. $msg $perf\n";
exit 0;



#ICINGA2 CONFIGURATION VARABLES 
#  Argument	    Value Type    Value	            Condition(set_if)	      Description
#  -H	          String	      $host.address$		                        Connect to the host's IP/FQDN
#  -u	          String	      $opensearch_user$		                      Username
#  -p	          String	      $opensearch_password$		                  Password
#  -S	          String		                     $opensearch_ssl$	        Enable SSL (HTTPS)
#  -k          	String		                     $opensearch_insecure$	  Ignore Cert Errors
#  --nodes    	String	      $opensearch_nodes$		                    Expected Node Count
#  --heap-crit	String	      $opensearch_heap$		                      Critical Heap %
#  --heap-warn	String	      $opensearch_heap_warn$		                Warning Heap %
#
#
