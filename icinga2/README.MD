# Icinga Plugin: check\_opensearch.pl

## Overview
![schema](./doc.png)
**check\_opensearch.pl** is a lightweight monitoring plugin designed for **OpenSearch** and **Elasticsearch** clusters.

Unlike standard plugins, this script is **"Pure Perl"** and dependency-free. It does **not** require installing external CPAN modules (like `JSON` or `LWP::UserAgent`), which keeps your monitoring server clean. Instead, it utilizes the system's native `curl` binary and Perl Regular Expressions to parse data.

### Key Features

  * **Cluster Health:** Checks if status is Green, Yellow, or Red.
  * **JVM Heap Usage:** Alerts if memory usage exceeds defined percentages.
  * **Node Count:** Alerts if the number of active nodes drops below expectation (detects split-brain).
  * **Secure:** Supports HTTPS (`--ssl`), Authentication (`-u/-p`), and self-signed certificates (`--insecure`).

-----

## Prerequisites

Before using this plugin, ensure the following are installed on the server running the check (usually the Icinga satellite or master):

1.  **Perl** (Pre-installed on almost all Linux distributions).
2.  **Curl** (Used to perform the API requests).
3.  **Network Access:** The Icinga server must be able to reach the OpenSearch API port (default: `9200`).

-----

## Installation

1.  **Copy the script** to your Icinga Plugin directory (usually `/usr/lib/nagios/plugins/`).

    ```bash
    cp check_opensearch.pl /usr/lib/nagios/plugins/
    ```

2.  **Make it executable**:

    ```bash
    chmod +x /usr/lib/nagios/plugins/check_opensearch.pl
    ```

3.  **Verify ownership** (ensure the `nagios` or `icinga` user can execute it):

    ```bash
    chown root:icinga /usr/lib/nagios/plugins/check_opensearch.pl
    ```

-----

## CLI Usage

You can test the script manually from the command line before adding it to Icinga.

### Command Arguments

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-H`, `--host` | Hostname or IP address of the node. | `localhost` |
| `-P`, `--port` | The API port. | `9200` |
| `-u`, `--user` | Username (if security is enabled). | (None) |
| `-p`, `--password` | Password. | (None) |
| `-S`, `--ssl` | Use HTTPS instead of HTTP. | Disabled |
| `-k`, `--insecure` | Ignore SSL certificate errors (self-signed). | Disabled |
| `--heap-warn` | Warning threshold for JVM Heap %. | `75` |
| `--heap-crit` | Critical threshold for JVM Heap %. | `90` |
| `--nodes` | Expected number of nodes in the cluster. | `0` (Disabled) |

### Example Command

```bash
./check_opensearch.pl -H 192.168.1.50 -u admin -p mypass --ssl --insecure --nodes 3
```

**Output:**

```text
OK - Cluster Green. Nodes: 3, Max Heap: 45%, Unassigned: 0, Rejected: 0 | nodes=3;;3 heap_max=45%;75;90 unassigned=0 rejected=0
```

-----

## Icinga 2 Configuration

To implement this check in Icinga 2, you need to define a **Command**, a **Service**, and configure your **Host** variables.

### 1\. CheckCommand Definition

Add this to `commands.conf`. This maps Icinga variables to the script arguments.

```icinga
object CheckCommand "opensearch_health" {
    import "plugin-check-command"
    command = [ PluginDir + "/check_opensearch.pl" ]

    arguments = {
        "-H" = { value = "$opensearch_address$", description = "Host Address" }
        "-P" = { value = "$opensearch_port$", description = "Port" }
        "-u" = { value = "$opensearch_user$", description = "Username" }
        "-p" = { value = "$opensearch_password$", description = "Password" }
        "--ssl" = { set_if = "$opensearch_ssl$", description = "Enable HTTPS" }
        "--insecure" = { set_if = "$opensearch_insecure$", description = "Ignore Cert Errors" }
        "--heap-warn" = { value = "$opensearch_heap_warn$" }
        "--heap-crit" = { value = "$opensearch_heap_crit$" }
        "--nodes" = { value = "$opensearch_min_nodes$" }
    }

    // Default Fallbacks
    vars.opensearch_address = "$address$"
    vars.opensearch_port = 9200
    vars.opensearch_ssl = false
    vars.opensearch_insecure = false 
}
```

### 2\. Service Definition

Add this to `services.conf`. This applies the check to any host that has the `opensearch_user` variable defined.

```icinga
apply Service "opensearch-health" {
    import "generic-service"
    check_command = "opensearch_health"
    
    // Apply to any host with OpenSearch credentials configured
    assign where host.vars.opensearch_user != ""
}
```

### 3\. Host Configuration

Add the specific variables to your host object in `hosts.conf`.

```icinga
object Host "os-node-01" {
    import "generic-host"
    address = "10.0.0.50"

    // OpenSearch Variables
    vars.opensearch_user = "admin"
    vars.opensearch_password = "SecretPassword123"
    vars.opensearch_ssl = true        // Set to false for HTTP
    vars.opensearch_insecure = true   // Set to true if using self-signed certs
    vars.opensearch_heap_warn = 80
    vars.opensearch_heap_crit = 90
    vars.opensearch_min_nodes = 3     // Alert if we see fewer than 3 nodes
}
```

-----

## Troubleshooting

### Return Codes

  * **OK (0):** Cluster status is Green, and Heap usage is below warning levels.
  * **WARNING (1):** Cluster status is Yellow (replicas initializing) OR Heap usage is above the Warning threshold.
  * **CRITICAL (2):** Cluster status is Red (data missing), Heap is above Critical threshold, node count is lower than expected, or the connection to the API failed.

### Common Errors

  * **Connection Refused:** Check if OpenSearch is running and if the port (9200) is open in the firewall.
  * **401 Unauthorized:** Check your username and password in the Host variables.
  * **Certificate Error:** If using a self-signed certificate, ensure `vars.opensearch_insecure = true` is set.
