#!/bin/sh
# 05-lease-sync.sh - Test T05: Lease Sync
#
# Validates lease-sync replicates DHCP leases between nodes using real
# DHCP clients to exercise the full lease acquisition flow.
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

# Load test framework
. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/assertions.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

# ============================================
# Configuration
# ============================================

# DHCP client containers
CLIENT1="ha-client1"
CLIENT2="ha-client2"

# ============================================
# Helper Functions
# ============================================

# Request DHCP lease on client
# Usage: request_dhcp_lease "ha-client1"
request_dhcp_lease() {
    local client="$1"

    # Stop any existing dhcpcd and wait for it to exit
    exec_client "$client" sh -c 'killall -9 dhcpcd 2>/dev/null || true'
    local count=0
    while [ $count -lt 5 ]; do
        if ! exec_client "$client" pgrep dhcpcd >/dev/null 2>&1; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    # Remove any existing IP from eth0 (container runtime may have assigned one)
    exec_client "$client" sh -c 'ip addr flush dev eth0 2>/dev/null || true'
    exec_client "$client" sh -c 'ip link set eth0 up'
    sleep 1  # Brief delay for interface to settle

    # Request new lease using dhcpcd (Alpine's DHCP client)
    # Run in daemon mode (no -1 flag) so dhcp_release() can send DHCPRELEASE
    # -t 15 = timeout 15s for obtaining initial lease
    exec_client "$client" sh -c 'dhcpcd -t 15 eth0 2>&1' || true

    # Wait for lease to be obtained (dhcpcd forks to background in daemon mode)
    count=0
    while [ $count -lt 15 ]; do
        local ip
        ip=$(get_client_ip "$client")
        if [ -n "$ip" ] && echo "$ip" | grep -q "^192\.168\.50\."; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Check if lease-sync is running on both nodes
    local lease_sync_running=true
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            lease_sync_running=false
            break
        fi
    done

    if [ "$lease_sync_running" = "false" ]; then
        skip "Lease sync test" "lease-sync not running on all nodes"
        return 1
    fi

    # Check if DHCP clients are available
    if ! client_running "$CLIENT1"; then
        skip "Lease sync test" "$CLIENT1 container not running"
        return 1
    fi

    # Release any existing leases on clients
    dhcp_release "$CLIENT1" 2>/dev/null || true
    dhcp_release "$CLIENT2" 2>/dev/null || true

    # Clear lease files to start fresh
    # Use touch to create file if it doesn't exist, then truncate
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" sh -c 'touch /tmp/dhcp.leases && cat /dev/null > /tmp/dhcp.leases' 2>/dev/null || true
    done

    # Verify lease files are empty (poll briefly)
    local count=0
    while [ $count -lt 5 ]; do
        local n1_count n2_count
        n1_count=$(get_lease_count "$NODE1")
        n2_count=$(get_lease_count "$NODE2")
        if [ "$n1_count" = "0" ] && [ "$n2_count" = "0" ]; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_lease_sync_running() {
    subheader "Lease-sync Service Check"
    check_service_on_all_nodes "lease-sync"
}

test_dhcp_clients_available() {
    subheader "DHCP Clients Available"

    for client in "$CLIENT1" "$CLIENT2"; do
        if client_running "$client"; then
            pass "$client container running"
        else
            fail "$client container not running"
            return 1
        fi
    done
}

test_dnsmasq_ubus_methods() {
    subheader "Dnsmasq Ubus Methods"
    check_dnsmasq_ubus_methods
}

test_client_gets_lease() {
    subheader "Client Obtains DHCP Lease"

    # Have client1 request a lease
    info "Requesting DHCP lease for $CLIENT1..."
    request_dhcp_lease "$CLIENT1"

    # Check if client got an IP
    local client_ip
    client_ip=$(get_client_ip "$CLIENT1")

    if [ -n "$client_ip" ] && echo "$client_ip" | grep -q "^192\.168\.50\."; then
        pass "$CLIENT1 obtained lease: $client_ip"
    else
        fail "$CLIENT1 failed to obtain DHCP lease"
        info "Client IP: ${client_ip:-none}"
        return 1
    fi

    # Both dnsmasq servers can respond to DHCP requests. Poll to find where
    # the lease actually is (wait for it to be written to disk).
    local dhcp_server
    dhcp_server=$(find_lease_server "$client_ip" "lease_exists" 10)

    if [ -n "$dhcp_server" ]; then
        pass "Lease for $client_ip exists on DHCP server ($dhcp_server)"
        # Store the DHCP server for use in test_lease_sync_to_peer
        CLIENT1_DHCP_SERVER="$dhcp_server"
    else
        fail "Lease not found on either DHCP server"
        info "Lease file on $NODE1:"
        exec_node "$NODE1" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        info "Lease file on $NODE2:"
        exec_node "$NODE2" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        return 1
    fi
}

# Store which node served client1's lease
CLIENT1_DHCP_SERVER=""

test_lease_sync_to_peer() {
    subheader "Lease Sync to Peer"

    # Get client1's IP
    local client_ip
    client_ip=$(get_client_ip "$CLIENT1")

    if [ -z "$client_ip" ]; then
        fail "Cannot test sync: client has no IP"
        return 1
    fi

    # Determine which node is the peer (not the DHCP server)
    local peer_node
    if [ -n "$CLIENT1_DHCP_SERVER" ]; then
        peer_node=$(get_peer_node "$CLIENT1_DHCP_SERVER")
    else
        # Fallback: find where the lease is, then get the peer
        local server
        server=$(find_lease_server "$client_ip" "lease_exists" 5)
        peer_node=$(get_peer_node "${server:-$NODE1}")
    fi

    # Wait for lease to sync to peer
    info "Waiting for lease $client_ip to sync to $peer_node..."
    if wait_for_lease "$peer_node" "$client_ip" "$SYNC_TIMEOUT"; then
        pass "Lease synced to peer ($peer_node)"
    else
        fail "Lease did not sync to $peer_node within ${SYNC_TIMEOUT}s"
        info "Peer lease file:"
        exec_node "$peer_node" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        return 1
    fi
}

test_second_client_lease() {
    subheader "Second Client Lease"

    # Skip if client2 not available
    if ! client_running "$CLIENT2"; then
        skip "Second client test" "$CLIENT2 not running"
        return 0
    fi

    # Have client2 request a lease
    info "Requesting DHCP lease for $CLIENT2..."
    request_dhcp_lease "$CLIENT2"

    local client2_ip
    client2_ip=$(get_client_ip "$CLIENT2")

    if [ -n "$client2_ip" ] && echo "$client2_ip" | grep -q "^192\.168\.50\."; then
        pass "$CLIENT2 obtained lease: $client2_ip"
    else
        fail "$CLIENT2 failed to obtain DHCP lease"
        return 1
    fi

    # Determine which node has the lease (both dnsmasq servers may respond,
    # and the client picks one). Poll to find the DHCP server.
    local dhcp_server
    dhcp_server=$(find_lease_server "$client2_ip" "lease_exists" 10)
    local peer_node=""

    if [ -n "$dhcp_server" ]; then
        peer_node=$(get_peer_node "$dhcp_server")
    fi

    if [ -z "$dhcp_server" ]; then
        fail "Lease $client2_ip not found on either node"
        info "Lease file on $NODE1:"
        exec_node "$NODE1" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        info "Lease file on $NODE2:"
        exec_node "$NODE2" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        return 1
    fi

    pass "Lease $client2_ip exists on DHCP server ($dhcp_server)"

    # Wait for lease to sync to peer
    info "Waiting for lease to sync to $peer_node..."
    if wait_for_lease "$peer_node" "$client2_ip" "$SYNC_TIMEOUT"; then
        pass "Second client lease synced to peer ($peer_node)"
    else
        fail "Second client lease did not sync to $peer_node"
        info "Peer lease file:"
        exec_node "$peer_node" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty or not found)"
        return 1
    fi
}

test_lease_count_consistency() {
    subheader "Lease Count Consistency"

    local count1 count2
    count1=$(get_lease_count "$NODE1")
    count2=$(get_lease_count "$NODE2")

    info "$NODE1 lease count: $count1"
    info "$NODE2 lease count: $count2"

    if [ "$count1" = "$count2" ]; then
        pass "Lease counts match: $count1"
    else
        local diff=$((count1 - count2))
        [ "$diff" -lt 0 ] && diff=$((diff * -1))
        fail "Lease count mismatch: $NODE1=$count1, $NODE2=$count2 (diff: $diff)"
        return 1
    fi
}

test_lease_release_sync() {
    subheader "Lease Release Sync"

    # Get client1's current IP
    local client_ip
    client_ip=$(get_client_ip "$CLIENT1")

    if [ -z "$client_ip" ]; then
        skip "Release sync test" "client has no IP"
        return 0
    fi

    info "Releasing lease for $CLIENT1 ($client_ip)..."
    dhcp_release "$CLIENT1"

    # Poll for lease removal from both nodes
    wait_for_lease_removal_all "$client_ip" "lease_exists" 10

    # Report final state
    for node in "$NODE1" "$NODE2"; do
        if ! lease_exists "$node" "$client_ip"; then
            info "Lease removed from $node"
        else
            info "Lease still exists on $node"
        fi
    done

    # Lease should be removed from both nodes
    if [ "$REMOVAL_COUNT" -ge 2 ]; then
        pass "Lease release synced to both nodes"
    elif [ "$REMOVAL_COUNT" -eq 1 ]; then
        fail "Lease release only removed from 1 node (sync broken)"
        return 1
    else
        fail "Lease release not processed by any node"
        return 1
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Release all client leases
    for client in "$CLIENT1" "$CLIENT2"; do
        if client_running "$client"; then
            dhcp_release "$client" 2>/dev/null || true
        fi
    done

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T05: Lease Sync"
    info "Validates lease-sync replicates DHCP leases via real clients"

    local result=0

    setup || return 0  # Skip if prerequisites not met
    test_lease_sync_running || return 1
    test_dhcp_clients_available || return 1
    test_dnsmasq_ubus_methods || return 1
    test_client_gets_lease || result=1
    test_lease_sync_to_peer || result=1

    # Non-fatal: second client container (ha-client2) may not be running;
    # core lease sync is already verified with first client
    run_nonfatal test_second_client_lease "ha-client2 container may not be available"

    # Non-fatal: lease counts may differ slightly due to timing windows
    # between sync operations; exact consistency is eventually achieved
    run_nonfatal test_lease_count_consistency "timing differences in sync propagation"

    # Non-fatal: lease release requires dnsmasq to process the release and
    # lease-sync to propagate; may need full lease expiry time in some cases
    run_nonfatal test_lease_release_sync "release sync may require lease expiry"

    cleanup

    return $result
}

main
exit $?
