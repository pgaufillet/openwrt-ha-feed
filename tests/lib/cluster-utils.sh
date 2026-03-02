#!/bin/sh
# cluster-utils.sh - HA cluster-specific test utilities
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# Requires: lib/common.sh to be sourced first
#
# Usage: Source after common.sh:
#   . ./lib/common.sh
#   . ./lib/cluster-utils.sh

# ============================================
# Shared Test Helpers
# ============================================
# These helpers consolidate common test patterns to reduce code duplication.

# Get list of active cluster nodes (NODE1, NODE2, and optionally NODE3 if running)
# Usage: nodes=$(get_active_nodes)
get_active_nodes() {
    local nodes="$NODE1 $NODE2"
    if node_running "$NODE3"; then
        nodes="$nodes $NODE3"
    fi
    echo "$nodes"
}

# Check if a service is running on all cluster nodes
# Usage: check_service_on_all_nodes "keepalived" [wait_timeout]
# Returns: 0 if service running on all nodes, 1 otherwise
# Outputs: pass/fail messages for each node
check_service_on_all_nodes() {
    local service="$1"
    local wait_timeout="${2:-0}"
    local all_running=true

    for node in $(get_active_nodes); do
        if [ "$wait_timeout" -gt 0 ]; then
            if wait_for_service "$node" "$service" "$wait_timeout"; then
                pass "$service running on $node"
            else
                fail "$service not running on $node"
                all_running=false
            fi
        else
            if service_running "$node" "$service"; then
                pass "$service running on $node"
            else
                fail "$service not running on $node"
                all_running=false
            fi
        fi
    done

    [ "$all_running" = "true" ]
}

# Check if dnsmasq ubus methods (add_lease, delete_lease) are available
# Usage: check_dnsmasq_ubus_methods
# Returns: 0 if all methods available on all nodes, 1 otherwise
# Outputs: pass/fail messages for each method on each node
check_dnsmasq_ubus_methods() {
    local all_ok=true

    for node in $(get_active_nodes); do
        local methods
        methods=$(exec_node "$node" ubus -v list dnsmasq 2>/dev/null || echo "")

        if echo "$methods" | grep -q "add_lease"; then
            pass "add_lease method available on $node"
        else
            fail "add_lease method missing on $node"
            all_ok=false
        fi

        if echo "$methods" | grep -q "delete_lease"; then
            pass "delete_lease method available on $node"
        else
            fail "delete_lease method missing on $node"
            all_ok=false
        fi
    done

    [ "$all_ok" = "true" ]
}

# Check for split-brain condition (multiple nodes have VIP or none has VIP)
# Usage: check_no_split_brain
# Returns: 0 if exactly one node has VIP, 1 otherwise
# Outputs: pass/fail message
check_no_split_brain() {
    local vip_count=0
    local vip_nodes=""

    for node in $(get_active_nodes); do
        if has_vip "$node"; then
            vip_count=$((vip_count + 1))
            vip_nodes="$vip_nodes $node"
        fi
    done

    if [ "$vip_count" -gt 1 ]; then
        fail "Split-brain detected: multiple nodes have VIP:$vip_nodes"
        return 1
    elif [ "$vip_count" -eq 0 ]; then
        fail "No MASTER: no node has VIP"
        return 1
    else
        pass "Exactly one node has VIP (no split-brain)"
        return 0
    fi
}

# Wait for VIP to appear on any node
# Usage: wait_for_vip_anywhere [timeout]
# Returns: 0 if VIP assigned to any node, 1 on timeout
# Sets VIP_OWNER variable to the node that has the VIP
wait_for_vip_anywhere() {
    local timeout="${1:-30}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        VIP_OWNER=$(get_vip_owner)
        if [ -n "$VIP_OWNER" ]; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    VIP_OWNER=""
    return 1
}

# Wait for a service to stop running on a node
# Usage: wait_for_service_stopped "node1" "keepalived" [timeout]
# Returns: 0 if service stopped, 1 on timeout
wait_for_service_stopped() {
    local node="$1"
    local service="$2"
    local timeout="${3:-10}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if ! service_running "$node" "$service"; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# Wait for file content to match a pattern on a node
# Usage: wait_for_file_content "node1" "/path/file" "pattern" [timeout]
# Returns: 0 if pattern found, 1 on timeout
wait_for_file_content() {
    local node="$1"
    local path="$2"
    local pattern="$3"
    local timeout="${4:-$SYNC_TIMEOUT}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if exec_node "$node" grep -q "$pattern" "$path" 2>/dev/null; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# Wait for lease to be absent from a node
# Usage: wait_for_lease_absent "node1" "192.168.50.100" [timeout]
# Returns: 0 if lease absent, 1 on timeout
wait_for_lease_absent() {
    local node="$1"
    local ip="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if ! lease_exists "$node" "$ip"; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# ============================================
# Container Execution Helpers
# ============================================

# Execute command in a container node
# Usage: exec_node "node1" "command" "args..."
exec_node() {
    local node="$1"
    shift
    $CONTAINER_RUNTIME exec "$node" "$@"
}

# Execute command in node1
# Usage: exec_node1 "command" "args..."
exec_node1() {
    exec_node "$NODE1" "$@"
}

# Execute command in node2
# Usage: exec_node2 "command" "args..."
exec_node2() {
    exec_node "$NODE2" "$@"
}

# Execute command in node3
# Usage: exec_node3 "command" "args..."
exec_node3() {
    exec_node "$NODE3" "$@"
}

# Check if a node container is running
# Usage: node_running "node1"
node_running() {
    local node="$1"
    $CONTAINER_RUNTIME ps --filter "name=^${node}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${node}$"
}

# ============================================
# VRRP State Helpers
# ============================================

# Get VRRP state from a node (MASTER, BACKUP, STOPPED, or UNKNOWN)
# Usage: vrrp_state=$(get_vrrp_state "node1")
#
# This function first tries to query keepalived via ubus for authoritative state
# (become_master/release_master counters). If ubus stats are unavailable (e.g., in
# container test environments), it falls back to VIP-based inference.
get_vrrp_state() {
    local node="$1"
    local state="UNKNOWN"

    # Check if keepalived is running first
    # Note: Don't use pgrep -x as process may be /usr/sbin/keepalived (full path)
    if ! exec_node "$node" pgrep keepalived >/dev/null 2>&1; then
        echo "STOPPED"
        return
    fi

    # Query keepalived via ubus for authoritative state
    # This matches the approach used in the LuCI status page (rpcd/ha-cluster)
    local keepalived_dump
    keepalived_dump=$(exec_node "$node" ubus call keepalived dump 2>/dev/null)

    # Check if dump has actual content (not just empty braces)
    local has_stats=false
    if [ -n "$keepalived_dump" ] && echo "$keepalived_dump" | grep -q '"become_master"'; then
        has_stats=true
    fi

    if [ "$has_stats" = "true" ]; then
        # Parse the JSON to extract become_master and release_master counters
        # If become_master > release_master, node is MASTER; otherwise BACKUP
        local become_master release_master
        become_master=$(echo "$keepalived_dump" | jsonfilter -e '@.status.*.stats.become_master' 2>/dev/null | head -1)
        release_master=$(echo "$keepalived_dump" | jsonfilter -e '@.status.*.stats.release_master' 2>/dev/null | head -1)

        if [ -n "$become_master" ] && [ -n "$release_master" ]; then
            if [ "$become_master" -gt "$release_master" ]; then
                state="MASTER"
            else
                state="BACKUP"
            fi
        else
            # jsonfilter failed, try fallback parsing with grep
            # Note: JSON may have space after colon, e.g. "become_master": 1
            become_master=$(echo "$keepalived_dump" | grep -o '"become_master": *[0-9]*' | grep -o '[0-9]*$' | head -1)
            release_master=$(echo "$keepalived_dump" | grep -o '"release_master": *[0-9]*' | grep -o '[0-9]*$' | head -1)

            if [ -n "$become_master" ] && [ -n "$release_master" ]; then
                if [ "$become_master" -gt "$release_master" ]; then
                    state="MASTER"
                else
                    state="BACKUP"
                fi
            fi
        fi
    fi

    # Fallback: if ubus stats not available, infer from VIP ownership
    # This is less authoritative but works in container test environments
    if [ "$state" = "UNKNOWN" ]; then
        warn "VRRP state unavailable via ubus on $node, inferring from VIP (less reliable)"
        if has_vip "$node"; then
            state="MASTER"
        else
            state="BACKUP"
        fi
    fi

    echo "$state"
}

# Check if a node has the VIP assigned
# Usage: if has_vip "node1"; then ...
has_vip() {
    local node="$1"
    exec_node "$node" ip addr show 2>/dev/null | grep -q "$VIP_ADDRESS"
}

# Get which node has the VIP (returns node name or empty)
# Usage: master=$(get_vip_owner)
get_vip_owner() {
    for node in $(get_active_nodes); do
        if has_vip "$node"; then
            echo "$node"
            return 0
        fi
    done
    echo ""
}

# Count nodes in a specific VRRP state
# Usage: count=$(count_nodes_in_state "BACKUP")
count_nodes_in_state() {
    local target_state="$1"
    local count=0

    for node in $(get_active_nodes); do
        local state
        state=$(get_vrrp_state "$node")
        if [ "$state" = "$target_state" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# Get nodes in a specific VRRP state (space-separated)
# Usage: backups=$(get_nodes_in_state "BACKUP")
get_nodes_in_state() {
    local target_state="$1"
    local nodes=""

    for node in $(get_active_nodes); do
        local state
        state=$(get_vrrp_state "$node")
        if [ "$state" = "$target_state" ]; then
            nodes="$nodes $node"
        fi
    done
    echo "$nodes" | sed 's/^ *//'
}

# Get the node with the highest priority (expected MASTER)
# Usage: expected_master=$(get_highest_priority_node)
get_highest_priority_node() {
    local highest_node=""
    local highest_priority=0

    for node in $(get_active_nodes); do
        local priority
        priority=$(uci_get "$node" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
        if [ "$priority" -gt "$highest_priority" ]; then
            highest_priority="$priority"
            highest_node="$node"
        fi
    done
    echo "$highest_node"
}

# Get the node with the second-highest priority (expected first failover target)
# Usage: secondary=$(get_second_priority_node)
get_second_priority_node() {
    local nodes_sorted=""
    local priorities=""

    # Collect node:priority pairs
    for node in $(get_active_nodes); do
        local priority
        priority=$(uci_get "$node" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
        priorities="$priorities $priority:$node"
    done

    # Sort by priority (descending) and get second
    echo "$priorities" | tr ' ' '\n' | sort -t: -k1 -rn | sed -n '2p' | cut -d: -f2
}

# Wait for VIP to appear on a specific node
# Usage: wait_for_vip "node1" [timeout]
wait_for_vip() {
    local node="$1"
    local timeout="${2:-$FAILOVER_TIMEOUT}"
    wait_for "VIP on $node" "$timeout" "has_vip $node"
}

# Wait for VIP to move from one node to another
# Usage: wait_for_vip_failover "from_node" "to_node" [timeout]
wait_for_vip_failover() {
    local from_node="$1"
    local to_node="$2"
    local timeout="${3:-$FAILOVER_TIMEOUT}"

    info "Waiting for VIP failover: $from_node → $to_node"

    local count=0
    while [ $count -lt "$timeout" ]; do
        local owner
        owner=$(get_vip_owner)
        if [ "$owner" = "$to_node" ]; then
            info "VIP failover complete after ${count}s"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    info "Timeout: VIP owner is $(get_vip_owner)"
    return 1
}

# Wait for VRRP to stabilize (exactly one node has VIP)
# Usage: wait_for_vrrp_stable [timeout]
# Returns: 0 if stable (exactly one node has VIP), 1 if timed out
wait_for_vrrp_stable() {
    local timeout="${1:-15}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        local n1_vip n2_vip
        n1_vip=$(has_vip "$NODE1" && echo "1" || echo "0")
        n2_vip=$(has_vip "$NODE2" && echo "1" || echo "0")
        # Stable when exactly one node has VIP
        if [ "$n1_vip" != "$n2_vip" ]; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

# Get the peer node (the other node in the cluster)
# Usage: peer=$(get_peer_node "$dhcp_server")
get_peer_node() {
    local server="$1"
    if [ "$server" = "$NODE1" ]; then
        echo "$NODE2"
    else
        echo "$NODE1"
    fi
}

# ============================================
# Service Helpers
# ============================================

# Check if a service is running in a node
# Usage: service_running "node1" "keepalived"
# Note: BusyBox pgrep -x doesn't work well with full paths, so we use pattern match
service_running() {
    local node="$1"
    local service="$2"
    exec_node "$node" pgrep "$service" >/dev/null 2>&1
}

# Start a service in a node
# Uses procd service control for proper process management
# Usage: service_start "node1" "keepalived"
service_start() {
    local node="$1"
    local service="$2"

    case "$service" in
        keepalived|owsync|lease-sync)
            # These are managed by ha-cluster - restart the whole ha-cluster service
            # which will re-register all instances with procd
            # Note: This restarts all HA services, but ensures proper procd registration
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
            ;;
        dnsmasq)
            exec_node "$node" /etc/init.d/dnsmasq start 2>/dev/null || true
            ;;
        *)
            # Try init script
            exec_node "$node" /etc/init.d/"$service" start 2>/dev/null || true
            ;;
    esac
}

# Stop a service in a node
# Uses procd service control for proper process management and zombie prevention
# Usage: service_stop "node1" "keepalived"
# Returns: 0 if stopped, 1 if stop failed (service still running)
service_stop() {
    local node="$1"
    local service="$2"

    case "$service" in
        keepalived|owsync|lease-sync)
            # These are managed by ha-cluster's procd instances
            # Use ubus to stop just this instance without affecting others
            exec_node "$node" ubus call service delete "{\"name\":\"ha-cluster\",\"instance\":\"$service\"}" 2>/dev/null || true
            ;;
        dnsmasq)
            exec_node "$node" /etc/init.d/dnsmasq stop 2>/dev/null || true
            ;;
        *)
            # Fallback: try init script, then killall
            exec_node "$node" /etc/init.d/"$service" stop 2>/dev/null || \
                exec_node "$node" killall "$service" 2>/dev/null || true
            ;;
    esac

    if ! wait_for_service_stopped "$node" "$service" 5; then
        warn "Service $service did not stop on $node within timeout"
        return 1
    fi
    return 0
}

# Restart a service in a node
# Usage: service_restart "node1" "keepalived"
service_restart() {
    local node="$1"
    local service="$2"
    service_stop "$node" "$service"
    # service_stop already waits for stop, no extra sleep needed
    service_start "$node" "$service"
}

# Wait for a service to be running
# Usage: wait_for_service "node1" "keepalived" [timeout]
wait_for_service() {
    local node="$1"
    local service="$2"
    local timeout="${3:-$BOOT_TIMEOUT}"
    wait_for "$service on $node" "$timeout" "service_running $node $service"
}

# ============================================
# Config Sync Helpers
# ============================================

# Create a test file on a node
# Usage: create_test_file "node1" "/etc/config/test_sync" "content"
create_test_file() {
    local node="$1"
    local path="$2"
    local content="$3"
    # Note: -i flag required for stdin to be passed through to container
    echo "$content" | $CONTAINER_RUNTIME exec -i "$node" sh -c "cat > $path"
}

# Check if a file exists on a node
# Usage: file_exists_on_node "node1" "/etc/config/test_sync"
file_exists_on_node() {
    local node="$1"
    local path="$2"
    exec_node "$node" test -f "$path"
}

# Get file content from a node
# Usage: content=$(get_file_content "node1" "/etc/config/test_sync")
get_file_content() {
    local node="$1"
    local path="$2"
    exec_node "$node" cat "$path" 2>/dev/null
}

# Wait for file to appear on a node
# Usage: wait_for_file "node1" "/etc/config/test_sync" [timeout]
wait_for_file() {
    local node="$1"
    local path="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    wait_for "file $path on $node" "$timeout" "file_exists_on_node $node $path"
}

# Force owsync sync to all peers
# Usage: trigger_owsync "node1"
# Note: This performs an actual sync to all configured peers.
# Callers should use wait_for_file() or wait_for_file_content() to verify.
trigger_owsync() {
    local node="$1"
    # Get list of peer IPs from the owsync config
    local peers=$(exec_node "$node" grep '^peer=' /tmp/owsync.conf 2>/dev/null | cut -d= -f2)

    if [ -n "$peers" ]; then
        # Perform immediate sync to each peer using owsync connect
        for peer in $peers; do
            debug "Syncing $node to $peer..."
            exec_node "$node" /usr/bin/owsync connect "$peer" -c /tmp/owsync.conf 2>/dev/null || true
        done
    else
        # Fallback: just touch files to trigger daemon's inotify
        exec_node "$node" sh -c 'touch /etc/config/* 2>/dev/null || true'
    fi
    # Small delay for sync propagation
    sleep 1
}

# ============================================
# DHCP Lease Helpers
# ============================================

# Add a lease via ubus
# Usage: add_lease "node1" "192.168.50.100" "aa:bb:cc:dd:ee:ff" "test-host" "3600"
# Note: This adds the lease to dnsmasq but does NOT trigger lease-sync broadcast.
# Use broadcast_lease_event() after this if you need sync to other nodes.
add_lease() {
    local node="$1"
    local ip="$2"
    local mac="$3"
    local hostname="${4:-}"
    local expires="${5:-3600}"

    local json="{\"ip\":\"$ip\",\"mac\":\"$mac\",\"expires\":$expires"
    if [ -n "$hostname" ]; then
        json="$json,\"hostname\":\"$hostname\""
    fi
    json="$json}"

    exec_node "$node" ubus call dnsmasq add_lease "$json"
}

# Broadcast a lease event via ubus to trigger lease-sync
# Usage: broadcast_lease_event "node1" "add" "192.168.50.100" "aa:bb:cc:dd:ee:ff" "test-host" "3600"
# This simulates what the hotplug script does when a real DHCP event occurs.
# The action can be: add, del, old (update)
broadcast_lease_event() {
    local node="$1"
    local action="$2"
    local ip="$3"
    local mac="$4"
    local hostname="${5:-}"
    local expires="${6:-}"

    local now
    now=$(exec_node "$node" date +%s)
    local node_id
    node_id=$(exec_node "$node" cat /proc/sys/kernel/hostname)

    local json="{\"action\":\"$action\",\"ip\":\"$ip\",\"mac\":\"$mac\""
    [ -n "$hostname" ] && json="$json,\"hostname\":\"$hostname\""
    json="$json,\"node_id\":\"$node_id\",\"timestamp\":$now"
    [ -n "$expires" ] && json="$json,\"expires\":$expires"
    json="$json}"

    exec_node "$node" ubus send dhcp.lease "$json"
}

# Delete a lease via ubus
# Usage: delete_lease "node1" "192.168.50.100"
delete_lease() {
    local node="$1"
    local ip="$2"

    exec_node "$node" ubus call dnsmasq delete_lease "{\"ip\":\"$ip\"}"
}

# Check if a lease exists on a node
# Usage: lease_exists "node1" "192.168.50.100"
lease_exists() {
    local node="$1"
    local ip="$2"
    exec_node "$node" grep -q "$ip" /tmp/dhcp.leases 2>/dev/null
}

# Get lease count on a node
# Usage: count=$(get_lease_count "node1")
get_lease_count() {
    local node="$1"
    # Note: redirect must happen inside container, not locally
    exec_node "$node" sh -c 'cat /tmp/dhcp.leases 2>/dev/null | wc -l' || echo "0"
}

# Wait for lease to appear on a node
# Usage: wait_for_lease "node1" "192.168.50.100" [timeout]
wait_for_lease() {
    local node="$1"
    local ip="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    wait_for "lease $ip on $node" "$timeout" "lease_exists $node $ip"
}

# Poll both nodes to find which has a specific lease
# Args: $1=ip_address $2=check_function (default: lease_exists) $3=timeout (default: 10)
# Prints the node name that has the lease
# Usage: server=$(find_lease_server "$ip" "lease_exists" 10)
#        server=$(find_lease_server "$ipv6" "ipv6_lease_exists" 10)
find_lease_server() {
    local ip="$1"
    local check_fn="${2:-lease_exists}"
    local timeout="${3:-10}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if "$check_fn" "$NODE1" "$ip"; then
            echo "$NODE1"
            return 0
        elif "$check_fn" "$NODE2" "$ip"; then
            echo "$NODE2"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

# Poll for lease removal from both nodes
# Args: $1=ip_address $2=check_function (default: lease_exists) $3=timeout (default: 10)
# Sets REMOVAL_COUNT to the number of nodes where lease was removed
# Returns: 0 if removed from both nodes, 1 otherwise
# Usage: wait_for_lease_removal_all "$ip" "lease_exists" 10
wait_for_lease_removal_all() {
    local ip="$1"
    local check_fn="${2:-lease_exists}"
    local timeout="${3:-10}"
    local count=0

    REMOVAL_COUNT=0
    while [ $count -lt "$timeout" ]; do
        REMOVAL_COUNT=0
        for node in "$NODE1" "$NODE2"; do
            if ! "$check_fn" "$node" "$ip"; then
                REMOVAL_COUNT=$((REMOVAL_COUNT + 1))
            fi
        done
        if [ "$REMOVAL_COUNT" -ge 2 ]; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

# ============================================
# UCI Helpers
# ============================================

# Get UCI value from a node
# Usage: value=$(uci_get "node1" "ha-cluster.config.enabled")
uci_get() {
    local node="$1"
    local key="$2"
    exec_node "$node" uci get "$key" 2>/dev/null
}

# Set UCI value on a node
# Usage: uci_set "node1" "ha-cluster.config.enabled" "1"
uci_set() {
    local node="$1"
    local key="$2"
    local value="$3"
    exec_node "$node" uci set "${key}=${value}"
}

# Commit UCI changes on a node
# Usage: uci_commit "node1" "ha-cluster"
uci_commit() {
    local node="$1"
    local config="${2:-}"
    if [ -n "$config" ]; then
        exec_node "$node" uci commit "$config"
    else
        exec_node "$node" uci commit
    fi
}

# ============================================
# Network Helpers
# ============================================

# Get IP addresses for an interface on a node
# Usage: ips=$(get_interface_ips "node1" "eth1")
get_interface_ips() {
    local node="$1"
    local iface="$2"
    exec_node "$node" ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

# Check connectivity between nodes
# Usage: nodes_can_communicate
nodes_can_communicate() {
    exec_node "$NODE1" ping -c 1 -W 2 "$NODE2_BACKEND_IP" >/dev/null 2>&1 && \
    exec_node "$NODE2" ping -c 1 -W 2 "$NODE1_BACKEND_IP" >/dev/null 2>&1
}

# ============================================
# Cluster Lifecycle
# ============================================

# Start HA cluster on a node
# Usage: start_ha_cluster "node1"
start_ha_cluster() {
    local node="$1"
    exec_node "$node" /etc/init.d/ha-cluster start
}

# Stop HA cluster on a node
# Usage: stop_ha_cluster "node1"
stop_ha_cluster() {
    local node="$1"
    exec_node "$node" /etc/init.d/ha-cluster stop
}

# Wait for cluster to be healthy (all nodes running, VIP assigned)
# Usage: wait_for_cluster_healthy [timeout]
wait_for_cluster_healthy() {
    local timeout="${1:-$BOOT_TIMEOUT}"
    local count=0

    info "Waiting for cluster to become healthy..."
    while [ $count -lt "$timeout" ]; do
        local all_running=true
        local vip_owner

        for node in $(get_active_nodes); do
            if ! service_running "$node" keepalived; then
                all_running=false
                break
            fi
        done

        vip_owner=$(get_vip_owner)

        if [ "$all_running" = "true" ] && [ -n "$vip_owner" ]; then
            info "Cluster healthy: keepalived running on all nodes, VIP on $vip_owner"
            return 0
        fi

        sleep 1
        count=$((count + 1))
    done

    info "Timeout: Cluster not healthy"
    return 1
}

# Get cluster status summary
# Usage: print_cluster_status
print_cluster_status() {
    subheader "Cluster Status"

    local vip_owner
    vip_owner=$(get_vip_owner)

    for node in $(get_active_nodes); do
        local state
        state=$(get_vrrp_state "$node")
        printf "  %s: state=%s\n" "$node" "$state"
    done
    printf "  VIP (%s): owner=%s\n" "$VIP_ADDRESS" "${vip_owner:-none}"

    subheader "Services"
    for svc in keepalived owsync lease-sync dnsmasq; do
        local status_line="  $svc:"
        for node in $(get_active_nodes); do
            local status
            status=$(service_running "$node" "$svc" && echo "running" || echo "stopped")
            status_line="$status_line $node=$status"
        done
        printf "%s\n" "$status_line"
    done
}

# ============================================
# Process Management Helpers
# ============================================

# Kill a process on a node with a specific signal
# Usage: kill_process "node1" "keepalived" "SIGKILL"
# Returns: 0 if process was killed, 1 if not found
kill_process() {
    local node="$1"
    local process="$2"
    local signal="${3:-SIGKILL}"

    local pid
    pid=$(exec_node "$node" pgrep "$process" 2>/dev/null | head -1)

    if [ -z "$pid" ]; then
        warn "Process $process not found on $node"
        return 1
    fi

    debug "Killing $process (PID $pid) on $node with $signal"
    exec_node "$node" kill -"$signal" "$pid" 2>/dev/null
    return 0
}

# Wait for a process to respawn after being killed
# Usage: wait_for_respawn "node1" "keepalived" [timeout]
# Returns: 0 if process respawned, 1 on timeout
wait_for_respawn() {
    local node="$1"
    local process="$2"
    local timeout="${3:-10}"
    local count=0

    # First wait for process to die (if it hasn't already)
    while [ $count -lt 3 ]; do
        if ! service_running "$node" "$process"; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    # Now wait for respawn
    count=0
    while [ $count -lt "$timeout" ]; do
        if service_running "$node" "$process"; then
            debug "$process respawned on $node after ${count}s"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    warn "$process did not respawn on $node within ${timeout}s"
    return 1
}

# ============================================
# Network Partition Helpers
# ============================================

# Create network partition by blocking traffic to peer
# Usage: create_network_partition "node1" "172.30.0.11"
# Note: Uses nft for fw4 compatibility (OpenWrt 24.10+), falls back to iptables
create_network_partition() {
    local node="$1"
    local peer_ip="$2"

    debug "Creating network partition on $node: blocking $peer_ip"
    # Try nft first (native fw4 on OpenWrt 24.10+)
    exec_node "$node" nft insert rule inet fw4 input ip saddr "$peer_ip" drop 2>/dev/null || \
        exec_node "$node" iptables -I INPUT -s "$peer_ip" -j DROP 2>/dev/null || true
    exec_node "$node" nft insert rule inet fw4 output ip daddr "$peer_ip" drop 2>/dev/null || \
        exec_node "$node" iptables -I OUTPUT -d "$peer_ip" -j DROP 2>/dev/null || true
}

# Heal network partition by removing firewall rules
# Usage: heal_network_partition "node1"
# Note: Uses fw4 reload to restore defaults (removes our custom rules)
heal_network_partition() {
    local node="$1"

    debug "Healing network partition on $node"
    # Reload fw4 to restore default rules (removes our custom nft rules)
    exec_node "$node" fw4 reload 2>/dev/null || true
    # Fallback: remove iptables rules if using legacy
    exec_node "$node" iptables -D INPUT -s "$NODE1_BACKEND_IP" -j DROP 2>/dev/null || true
    exec_node "$node" iptables -D INPUT -s "$NODE2_BACKEND_IP" -j DROP 2>/dev/null || true
    exec_node "$node" iptables -D OUTPUT -d "$NODE1_BACKEND_IP" -j DROP 2>/dev/null || true
    exec_node "$node" iptables -D OUTPUT -d "$NODE2_BACKEND_IP" -j DROP 2>/dev/null || true
}

# Heal all network partitions on all nodes
# Usage: heal_all_partitions
heal_all_partitions() {
    for node in $(get_active_nodes); do
        heal_network_partition "$node"
    done
}

# ============================================
# Traffic Capture Helpers
# ============================================

# Capture network traffic on a node
# Usage: capture_traffic "node1" "eth0" 5 "/tmp/capture.pcap"
# Returns: 0 if capture succeeded, 1 otherwise
capture_traffic() {
    local node="$1"
    local interface="$2"
    local duration="$3"
    local output_file="$4"

    debug "Capturing traffic on $node:$interface for ${duration}s"
    exec_node "$node" sh -c "timeout $duration tcpdump -i $interface -w $output_file 2>/dev/null &"
    sleep "$duration"
    # Wait a bit more for tcpdump to finish writing
    sleep 1
    return 0
}

# Verify no plaintext patterns in capture file
# Usage: verify_no_plaintext "node1" "/tmp/capture.pcap" "pattern1" "pattern2"
# Returns: 0 if no plaintext found, 1 if plaintext detected
# Note: Uses hexdump -C (BusyBox) instead of strings (not in OpenWrt)
verify_no_plaintext() {
    local node="$1"
    local capture_file="$2"
    shift 2
    local patterns="$@"

    for pattern in $patterns; do
        # Use hexdump -C which outputs readable hex+ASCII representation
        # grep -ai handles case-insensitive search and binary data
        if exec_node "$node" hexdump -C "$capture_file" 2>/dev/null | grep -ai "$pattern"; then
            warn "Plaintext pattern '$pattern' found in capture"
            return 1
        fi
    done
    return 0
}

# ============================================
# Advanced Lease Helpers
# ============================================

# Get all leases from a node via ubus
# Usage: leases=$(get_all_leases "node1")
# Returns: JSON array of leases
get_all_leases() {
    local node="$1"
    exec_node "$node" ubus call dnsmasq get_leases 2>/dev/null || echo '{"leases":[]}'
}

# Inject a lease directly into dnsmasq (bypassing lease-sync)
# This simulates stale data that should be cleaned up by startup reconciliation
# Usage: inject_lease_directly "node1" "192.168.50.100" "aa:bb:cc:dd:ee:ff" "test-host" "3600"
inject_lease_directly() {
    local node="$1"
    local ip="$2"
    local mac="$3"
    local hostname="${4:-*}"
    local expiry="${5:-3600}"

    # Calculate absolute expiry time
    local now
    now=$(exec_node "$node" date +%s)
    local abs_expiry=$((now + expiry))

    # Write directly to dhcp.leases file (bypasses lease-sync)
    # Format: <expiry> <mac> <ip> <hostname> <client-id>
    exec_node "$node" sh -c "echo '$abs_expiry $mac $ip $hostname *' >> /tmp/dhcp.leases"
}

# Get lease count via ubus (more authoritative than file parsing)
# Usage: count=$(get_ubus_lease_count "node1")
get_ubus_lease_count() {
    local node="$1"
    local leases count
    leases=$(get_all_leases "$node")
    # grep -c returns exit code 1 when no matches but still outputs "0"
    # Use subshell to ignore exit code and just capture output
    count=$(echo "$leases" | grep -c '"ip"' 2>/dev/null) || true
    echo "${count:-0}"
}

# Wait for lease to appear via ubus
# Usage: wait_for_ubus_lease "node1" "192.168.50.100" [timeout]
wait_for_ubus_lease() {
    local node="$1"
    local ip="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if get_all_leases "$node" | grep -q "\"$ip\""; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# Wait for lease to be absent via ubus
# Usage: wait_for_ubus_lease_absent "node1" "192.168.50.100" [timeout]
wait_for_ubus_lease_absent() {
    local node="$1"
    local ip="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if ! get_all_leases "$node" | grep -q "\"$ip\""; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# ============================================
# DHCP Client Helpers
# ============================================
# These helpers use actual DHCP clients in test containers to generate
# real DHCP traffic, which triggers the full hotplug chain:
# dnsmasq -> dhcp-script -> hotplug -> lease-sync -> broadcast
#
# This is essential for representative testing of lease synchronization.

# Client container names
CLIENT1="${CLIENT1:-ha-client1}"
CLIENT2="${CLIENT2:-ha-client2}"

# Execute command in a client container
# Usage: exec_client "ha-client1" "command" "args..."
exec_client() {
    local client="$1"
    shift
    $CONTAINER_RUNTIME exec "$client" "$@"
}

# Request a DHCP lease from a client container
# Usage: dhcp_ip=$(dhcp_request "ha-client1" [interface])
# Returns: The assigned IP address, or empty on failure
# Note: This triggers the full DHCP flow and hotplug events
dhcp_request() {
    local client="$1"
    local interface="${2:-eth0}"

    debug "Requesting DHCP lease on $client:$interface"

    # Release any existing lease and clear stale state files.
    # dhcpcd persists DUID and lease data in /var/lib/dhcpcd/; if stale,
    # it attempts REBIND instead of fresh DISCOVER, which fails when the
    # server doesn't recognize the old lease.
    exec_client "$client" dhcpcd -k "$interface" 2>/dev/null || true
    exec_client "$client" ip addr flush dev "$interface" 2>/dev/null || true
    exec_client "$client" rm -f "/var/lib/dhcpcd/${interface}.lease" /var/lib/dhcpcd/duid 2>/dev/null || true
    sleep 1

    # Request new lease with short timeout
    # Use -4 for IPv4 only (avoids IPv6 read-only filesystem errors in containers)
    # Use -1 for one attempt, -t for timeout
    exec_client "$client" dhcpcd -4 -1 -t 10 "$interface" 2>/dev/null

    # Wait for IP to be assigned
    sleep 2

    # Get the assigned IP
    local ip
    ip=$(exec_client "$client" ip -4 addr show dev "$interface" 2>/dev/null | \
         awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)

    if [ -n "$ip" ]; then
        debug "DHCP lease obtained: $ip"
        echo "$ip"
        return 0
    else
        warn "Failed to obtain DHCP lease on $client:$interface"
        return 1
    fi
}

# Release a DHCP lease from a client container
# Usage: dhcp_release "ha-client1" [interface]
dhcp_release() {
    local client="$1"
    local interface="${2:-eth0}"

    debug "Releasing DHCP lease on $client:$interface"
    exec_client "$client" dhcpcd -k "$interface" 2>/dev/null || true
    sleep 1
}

# Get the MAC address of a client's interface
# Usage: mac=$(get_client_mac "ha-client1" [interface])
get_client_mac() {
    local client="$1"
    local interface="${2:-eth0}"

    exec_client "$client" ip link show dev "$interface" 2>/dev/null | \
        awk '/link\/ether/ {print $2}' | head -1
}

# Get the current IP address of a client's interface
# Usage: ip=$(get_client_ip "ha-client1" [interface])
get_client_ip() {
    local client="$1"
    local interface="${2:-eth0}"

    exec_client "$client" ip -4 addr show dev "$interface" 2>/dev/null | \
        awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1
}

# Wait for a DHCP lease to appear on a cluster node (from a specific MAC)
# Usage: wait_for_dhcp_lease_by_mac "ha-node1" "aa:bb:cc:dd:ee:ff" [timeout]
# Returns: 0 if lease found, 1 on timeout
wait_for_dhcp_lease_by_mac() {
    local node="$1"
    local mac="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        if get_all_leases "$node" | grep -qi "$mac"; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# Check if a client container is running
# Usage: client_running "ha-client1"
client_running() {
    local client="$1"
    $CONTAINER_RUNTIME ps --filter "name=^${client}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${client}$"
}

# ============================================
# IPv6 DHCP Lease Helpers
# ============================================

# Request a DHCPv6 lease from a client container
# Usage: ipv6=$(dhcpv6_request "ha-client1" [interface])
# Returns: The assigned IPv6 address, or empty on failure
# Note: dhcpcd requests both IA_NA and IA_TA by default
dhcpv6_request() {
    local client="$1"
    local interface="${2:-eth0}"

    # Stop any existing dhcpcd (suppress all output)
    exec_client "$client" sh -c 'killall -9 dhcpcd 2>/dev/null || true' >/dev/null 2>&1
    sleep 1

    # Flush existing IPv6 addresses (keep link-local)
    exec_client "$client" sh -c "ip -6 addr flush dev $interface scope global 2>/dev/null || true" >/dev/null 2>&1
    exec_client "$client" ip link set "$interface" up >/dev/null 2>&1
    sleep 1

    # Request new lease - dhcpcd handles both IPv4 and IPv6
    # -t 20 = timeout 20s (IPv6 may take longer due to RA wait)
    # Redirect all output to prevent it from being captured
    exec_client "$client" sh -c "dhcpcd -t 20 $interface >/dev/null 2>&1" || true

    # Wait for IPv6 address to be assigned
    local count=0
    local ip=""
    while [ $count -lt 20 ]; do
        ip=$(get_client_ipv6 "$client" "$interface")
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

# Get the current global IPv6 address of a client's interface
# Usage: ip=$(get_client_ipv6 "ha-client1" [interface])
# Returns: First global scope IPv6 address (excludes link-local fe80::)
get_client_ipv6() {
    local client="$1"
    local interface="${2:-eth0}"

    # Get global scope IPv6 (fd00:: prefix in test environment)
    exec_client "$client" sh -c "ip -6 addr show dev $interface scope global 2>/dev/null | grep -oE 'fd00:[0-9a-f:]+' | head -1" 2>/dev/null || echo ""
}

# Check if an IPv6 lease exists on a node
# Usage: ipv6_lease_exists "node1" "fd00:192:168:50::105"
ipv6_lease_exists() {
    local node="$1"
    local ip="$2"
    exec_node "$node" grep -q "$ip" /tmp/dhcp.leases 2>/dev/null
}

# Wait for IPv6 lease to appear on a node
# Usage: wait_for_ipv6_lease "node1" "fd00:192:168:50::105" [timeout]
wait_for_ipv6_lease() {
    local node="$1"
    local ip="$2"
    local timeout="${3:-$SYNC_TIMEOUT}"
    wait_for "IPv6 lease $ip on $node" "$timeout" "ipv6_lease_exists $node $ip"
}

# Release DHCPv6 lease from a client
# Usage: dhcpv6_release "ha-client1" [interface]
dhcpv6_release() {
    local client="$1"
    local interface="${2:-eth0}"

    exec_client "$client" sh -c "dhcpcd -k $interface 2>/dev/null || killall dhcpcd 2>/dev/null || true" >/dev/null 2>&1
    sleep 1
}

# Get IPv6 lease count on a node
# Usage: count=$(get_ipv6_lease_count "node1")
get_ipv6_lease_count() {
    local node="$1"
    # Count lines containing IPv6 addresses from client LAN prefix
    # Note: grep -c returns 0 (with exit code 1) when no match, so we capture output
    # and only use fallback if the command fails entirely (e.g., file doesn't exist)
    local count
    count=$(exec_node "$node" sh -c 'grep -c "fd00:192:168:50:" /tmp/dhcp.leases 2>/dev/null')
    # If grep failed entirely (no output), return 0
    if [ -z "$count" ]; then
        echo "0"
    else
        # Strip whitespace and return
        echo "$count" | tr -d '[:space:]'
    fi
}

# ============================================
# odhcpd Detection Helpers
# ============================================

# Check if odhcpd is installed on a node
# Usage: if odhcpd_installed "node1"; then ...
odhcpd_installed() {
    local node="$1"
    exec_node "$node" which odhcpd >/dev/null 2>&1
}

# Check if odhcpd service is running on a node
# Usage: if odhcpd_running "node1"; then ...
odhcpd_running() {
    local node="$1"
    service_running "$node" "odhcpd"
}

# Check if odhcpd is disabled (installed but not enabled)
# Usage: if odhcpd_disabled "node1"; then ...
odhcpd_disabled() {
    local node="$1"
    if odhcpd_installed "$node"; then
        ! odhcpd_running "$node"
    else
        # Not installed = effectively disabled
        return 0
    fi
}

# Assert odhcpd is absent or disabled (for tests requiring dnsmasq-only DHCPv6)
# Usage: require_no_odhcpd "node1" || return 1
require_no_odhcpd() {
    local node="$1"
    if odhcpd_running "$node"; then
        fail "odhcpd is running on $node - test requires dnsmasq-only DHCPv6"
        info "Either disable odhcpd or skip this test"
        return 1
    fi
    return 0
}

# Disable odhcpd on a node (stop service and prevent restart)
# Also restarts dnsmasq so it can take over DHCPv6 duties
# Usage: disable_odhcpd "node1"
# Returns: 0 if disabled, 1 if not installed
disable_odhcpd() {
    local node="$1"
    if ! odhcpd_installed "$node"; then
        debug "odhcpd not installed on $node"
        return 0
    fi
    debug "Disabling odhcpd on $node..."
    exec_node "$node" /etc/init.d/odhcpd stop 2>/dev/null || true
    exec_node "$node" /etc/init.d/odhcpd disable 2>/dev/null || true
    # Wait for process to stop
    local count=0
    while [ $count -lt 5 ]; do
        if ! odhcpd_running "$node"; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    # Force kill if still running
    if odhcpd_running "$node"; then
        exec_node "$node" killall odhcpd 2>/dev/null || true
        sleep 1
    fi
    # Restart dnsmasq so it picks up DHCPv6 duties
    debug "Restarting dnsmasq on $node to enable DHCPv6..."
    exec_node "$node" /etc/init.d/dnsmasq restart 2>/dev/null || true
    sleep 2
    ! odhcpd_running "$node"
}

# Enable odhcpd on a node (restore to running state)
# Usage: enable_odhcpd "node1"
enable_odhcpd() {
    local node="$1"
    if ! odhcpd_installed "$node"; then
        return 0
    fi
    debug "Enabling odhcpd on $node..."
    exec_node "$node" /etc/init.d/odhcpd enable 2>/dev/null || true
    exec_node "$node" /etc/init.d/odhcpd start 2>/dev/null || true
}

# Check if SLAAC mode is configured (ra_slaac != '0')
# Usage: if slaac_enabled "node1"; then ...
slaac_enabled() {
    local node="$1"
    local ra_slaac
    ra_slaac=$(exec_node "$node" uci get dhcp.lan.ra_slaac 2>/dev/null || echo "1")
    [ "$ra_slaac" != "0" ]
}

# Check if stateful DHCPv6 mode is configured
# Usage: if stateful_dhcpv6_enabled "node1"; then ...
stateful_dhcpv6_enabled() {
    local node="$1"
    local dhcpv6
    dhcpv6=$(exec_node "$node" uci get dhcp.lan.dhcpv6 2>/dev/null || echo "")
    [ "$dhcpv6" = "server" ]
}

# ============================================
# odhcpd Bulk Operations
# ============================================

# Save odhcpd running state and disable on all nodes
# Sets ODHCPD_WAS_RUNNING_NODE1 and ODHCPD_WAS_RUNNING_NODE2 globals
# Usage: save_and_disable_odhcpd_all || return 1
save_and_disable_odhcpd_all() {
    ODHCPD_WAS_RUNNING_NODE1="false"
    ODHCPD_WAS_RUNNING_NODE2="false"

    for node in "$NODE1" "$NODE2"; do
        if odhcpd_running "$node"; then
            info "Disabling odhcpd on $node..."
            if [ "$node" = "$NODE1" ]; then
                ODHCPD_WAS_RUNNING_NODE1="true"
            else
                ODHCPD_WAS_RUNNING_NODE2="true"
            fi
            if ! disable_odhcpd "$node"; then
                fail "Failed to disable odhcpd on $node"
                return 1
            fi
            pass "odhcpd disabled on $node"
        fi
    done

    # Verify odhcpd is now stopped
    for node in "$NODE1" "$NODE2"; do
        if ! require_no_odhcpd "$node"; then
            fail "odhcpd still running on $node after disable attempt"
            return 1
        fi
    done
    pass "odhcpd disabled on all nodes"
    return 0
}

# Restore odhcpd on nodes where it was running before test
# Reads ODHCPD_WAS_RUNNING_NODE1 and ODHCPD_WAS_RUNNING_NODE2 globals
# Usage: restore_odhcpd_if_was_running
restore_odhcpd_if_was_running() {
    if [ "$ODHCPD_WAS_RUNNING_NODE1" = "true" ]; then
        info "Restoring odhcpd on $NODE1..."
        enable_odhcpd "$NODE1" || true
    fi
    if [ "$ODHCPD_WAS_RUNNING_NODE2" = "true" ]; then
        info "Restoring odhcpd on $NODE2..."
        enable_odhcpd "$NODE2" || true
    fi
}

# ============================================
# IPv6 VIP Helpers
# ============================================

# Check if a node has the IPv6 VIP assigned
# Usage: if has_vip6 "node1"; then ...
has_vip6() {
    local node="$1"
    exec_node "$node" ip -6 addr show 2>/dev/null | grep -q "${VIP6_ADDRESS:-fd00:192:168:50::254}"
}

# Wait for IPv6 VIP to appear on a specific node
# Usage: wait_for_vip6 "node1" [timeout]
wait_for_vip6() {
    local node="$1"
    local timeout="${2:-$FAILOVER_TIMEOUT}"
    wait_for "IPv6 VIP on $node" "$timeout" "has_vip6 $node"
}

# Get which node has the IPv6 VIP (returns node name or empty)
# Usage: master=$(get_vip6_owner)
get_vip6_owner() {
    for node in $(get_active_nodes); do
        if has_vip6 "$node"; then
            echo "$node"
            return 0
        fi
    done
    echo ""
}

# ============================================
# IPv6 Support Checks
# ============================================

# Check if IPv6 is enabled and nodes have IPv6 addresses
# Usage: check_ipv6_enabled || return 1
# Returns: 0 if IPv6 is enabled, 1 otherwise (with skip message)
check_ipv6_enabled() {
    # Check if IPv6 is enabled in kernel
    local has_ipv6
    has_ipv6=$(exec_node "$NODE1" cat /proc/net/if_inet6 2>/dev/null | wc -l)

    if [ "$has_ipv6" -le 0 ]; then
        return 1
    fi

    # Check if nodes have global IPv6 addresses
    local node1_ip6 node2_ip6
    node1_ip6=$(exec_node "$NODE1" ip -6 addr show scope global 2>/dev/null | grep "fd00:" | head -1)
    node2_ip6=$(exec_node "$NODE2" ip -6 addr show scope global 2>/dev/null | grep "fd00:" | head -1)

    if [ -z "$node1_ip6" ] || [ -z "$node2_ip6" ]; then
        return 1
    fi

    return 0
}

# Check IPv6 connectivity between nodes
# Usage: check_ipv6_connectivity
# Returns: 0 if connectivity works, non-zero otherwise
check_ipv6_connectivity() {
    # Try to ping node2 from node1 using IPv6
    exec_node "$NODE1" ping6 -c 1 -W 2 fd00:172:30::11 >/dev/null 2>&1
}
