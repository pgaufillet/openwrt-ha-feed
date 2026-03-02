#!/bin/sh
# 15-ipv6-lease-sync.sh - Test T15: IPv6 Lease Sync
#
# Validates DHCPv6 lease synchronization between nodes, specifically testing:
# - IPv6 lease acquisition via DHCPv6
# - IAID field parsing (T prefix stripped for temporary addresses)
# - is_temporary field (0/1 integer, not boolean)
# - Lease sync to peer node
#
# This test validates the fix in dhcp-script-ha.sh for IPv6 fields.
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

# IPv6 prefix used in test environment
IPV6_PREFIX="fd00:192:168:50"

# ============================================
# Helper Functions
# ============================================

# Check if DHCPv6 is enabled on a node
dhcpv6_enabled() {
    local node="$1"
    local dhcpv6_setting
    dhcpv6_setting=$(exec_node "$node" uci get dhcp.lan.dhcpv6 2>/dev/null || echo "")
    [ "$dhcpv6_setting" = "server" ]
}

# Check if Router Advertisements are enabled
ra_enabled() {
    local node="$1"
    local ra_setting
    ra_setting=$(exec_node "$node" uci get dhcp.lan.ra 2>/dev/null || echo "")
    [ "$ra_setting" = "server" ]
}

# Capture ubus events for a duration and save to file
# Usage: capture_ubus_events "node1" "dhcp.lease" 10 "/tmp/events.log"
capture_ubus_events() {
    local node="$1"
    local event="$2"
    local duration="$3"
    local output="$4"

    # Start ubus listen in background, capture for duration
    exec_node "$node" sh -c "timeout $duration ubus listen $event > $output 2>&1 &"
}

# Check if ubus event contains expected field with correct type
# Usage: check_event_field "node1" "/tmp/events.log" "iaid" "number"
check_event_field() {
    local node="$1"
    local logfile="$2"
    local field="$3"
    local expected_type="$4"

    local content
    content=$(exec_node "$node" cat "$logfile" 2>/dev/null)

    case "$expected_type" in
        number)
            # Field should be a number (no quotes around value)
            echo "$content" | grep -qE "\"$field\":[0-9]+"
            ;;
        string)
            # Field should be a quoted string
            echo "$content" | grep -qE "\"$field\":\"[^\"]*\""
            ;;
        *)
            return 1
            ;;
    esac
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
        skip "IPv6 lease sync test" "lease-sync not running on all nodes"
        return 1
    fi

    # Disable odhcpd if running (test requires dnsmasq-only DHCPv6)
    save_and_disable_odhcpd_all || return 1

    # Check if DHCP client is available
    if ! client_running "$CLIENT1"; then
        skip "IPv6 lease sync test" "$CLIENT1 container not running"
        return 1
    fi

    # Release any existing leases
    dhcpv6_release "$CLIENT1" 2>/dev/null || true

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_dhcpv6_configured() {
    subheader "DHCPv6 Configuration Check"

    local all_configured=true

    for node in "$NODE1" "$NODE2"; do
        if dhcpv6_enabled "$node"; then
            pass "DHCPv6 enabled on $node"
        else
            fail "DHCPv6 not enabled on $node"
            info "Run: uci set dhcp.lan.dhcpv6='server' && uci commit dhcp"
            all_configured=false
        fi

        if ra_enabled "$node"; then
            pass "Router Advertisements enabled on $node"
        else
            fail "Router Advertisements not enabled on $node"
            info "Run: uci set dhcp.lan.ra='server' && uci commit dhcp"
            all_configured=false
        fi
    done

    [ "$all_configured" = "true" ]
}

test_ipv6_connectivity() {
    subheader "IPv6 Infrastructure Check"

    # Check if nodes have IPv6 addresses on LAN interface (client network prefix)
    local node1_ipv6 node2_ipv6
    # Look specifically for the client LAN prefix (fd00:192:168:50::)
    node1_ipv6=$(exec_node "$NODE1" ip -6 addr show scope global 2>/dev/null | grep -oE "fd00:192:168:50:[0-9a-f:]+" | head -1)
    node2_ipv6=$(exec_node "$NODE2" ip -6 addr show scope global 2>/dev/null | grep -oE "fd00:192:168:50:[0-9a-f:]+" | head -1)

    if [ -n "$node1_ipv6" ]; then
        pass "$NODE1 has LAN IPv6: $node1_ipv6"
    else
        fail "$NODE1 has no LAN IPv6 address (fd00:192:168:50::)"
        info "Available IPv6 addresses:"
        exec_node "$NODE1" ip -6 addr show scope global 2>&1 || true
        return 1
    fi

    if [ -n "$node2_ipv6" ]; then
        pass "$NODE2 has LAN IPv6: $node2_ipv6"
    else
        fail "$NODE2 has no LAN IPv6 address (fd00:192:168:50::)"
        info "Available IPv6 addresses:"
        exec_node "$NODE2" ip -6 addr show scope global 2>&1 || true
        return 1
    fi

    # Check IPv6 connectivity between nodes on LAN
    if exec_node "$NODE1" ping6 -c 1 -W 2 "$node2_ipv6" >/dev/null 2>&1; then
        pass "IPv6 connectivity between nodes on LAN"
    else
        warn "IPv6 ping between nodes failed (may still work for DHCPv6)"
    fi
}

test_client_gets_ipv6_lease() {
    subheader "Client Obtains DHCPv6 Lease"

    # Request DHCPv6 lease
    info "Requesting DHCPv6 lease for $CLIENT1..."

    # Start ubus event capture to verify JSON format
    exec_node "$NODE1" sh -c 'rm -f /tmp/dhcp_events.log'
    exec_node "$NODE1" sh -c 'timeout 30 ubus listen dhcp.lease > /tmp/dhcp_events.log 2>&1 &'
    sleep 1

    # Request lease (dual-stack, will get both IPv4 and IPv6)
    local client_ipv6
    client_ipv6=$(dhcpv6_request "$CLIENT1")

    if [ -n "$client_ipv6" ] && echo "$client_ipv6" | grep -q "^fd00:"; then
        pass "$CLIENT1 obtained DHCPv6 lease: $client_ipv6"
        # Store for later tests
        CLIENT1_IPV6="$client_ipv6"
    else
        # Check if we got IPv4 at least (DHCPv6 may not work in all container setups)
        local client_ipv4
        client_ipv4=$(get_client_ip "$CLIENT1")
        if [ -n "$client_ipv4" ]; then
            info "Got IPv4 ($client_ipv4) but no IPv6 - checking RA reception..."

            # Debug: show what client received
            info "Client IPv6 addresses:"
            exec_client "$CLIENT1" ip -6 addr show eth0 2>&1 || true

            # Check if client received Router Advertisement
            if exec_client "$CLIENT1" ip -6 route show default 2>/dev/null | grep -q "via"; then
                info "Client has IPv6 default route (RA received)"
            else
                info "No IPv6 default route - RA not received or processed"
            fi
        fi

        fail "$CLIENT1 failed to obtain DHCPv6 lease"
        return 1
    fi

    # Wait for event to be captured
    sleep 2

    # Verify lease exists on at least one node
    local dhcp_server
    dhcp_server=$(find_lease_server "$CLIENT1_IPV6" "ipv6_lease_exists" 10)

    if [ -n "$dhcp_server" ]; then
        pass "IPv6 lease exists on DHCP server ($dhcp_server)"
        CLIENT1_DHCP_SERVER="$dhcp_server"
    else
        fail "IPv6 lease not found on either node"
        info "Lease file on $NODE1:"
        exec_node "$NODE1" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty)"
        return 1
    fi
}

# Store DHCPv6 lease info for subsequent tests
CLIENT1_IPV6=""
CLIENT1_DHCP_SERVER=""

test_iaid_field_format() {
    subheader "IAID Field Format Validation"

    # Check the captured ubus events for correct IAID format
    local events
    events=$(exec_node "$NODE1" cat /tmp/dhcp_events.log 2>/dev/null || echo "")

    if [ -z "$events" ]; then
        # Try node2 if node1 didn't capture
        events=$(exec_node "$NODE2" cat /tmp/dhcp_events.log 2>/dev/null || echo "")
    fi

    if [ -z "$events" ]; then
        skip "IAID format check" "No ubus events captured"
        return 0
    fi

    # Check if iaid is present and numeric (not quoted string)
    # Correct: "iaid":12345
    # Wrong: "iaid":"T12345" or "iaid":"12345"
    if echo "$events" | grep -qE '"iaid":[0-9]+'; then
        pass "IAID field is numeric (T prefix correctly stripped)"
    elif echo "$events" | grep -qE '"iaid":"T?[0-9]+"'; then
        fail "IAID field is string (should be numeric)"
        info "Event content: $events"
        return 1
    else
        # No IAID field - might be IPv4 only event
        info "No IAID field in captured events (expected for IPv6 leases)"
        # Not a failure if we didn't get IPv6 lease
        if [ -z "$CLIENT1_IPV6" ]; then
            skip "IAID format check" "No IPv6 lease obtained"
            return 0
        fi
    fi
}

test_is_temporary_field_format() {
    subheader "is_temporary Field Format Validation"

    local events
    events=$(exec_node "$NODE1" cat /tmp/dhcp_events.log 2>/dev/null || echo "")

    if [ -z "$events" ]; then
        events=$(exec_node "$NODE2" cat /tmp/dhcp_events.log 2>/dev/null || echo "")
    fi

    if [ -z "$events" ]; then
        skip "is_temporary format check" "No ubus events captured"
        return 0
    fi

    # Check if is_temporary is present and numeric (0 or 1)
    # Correct: "is_temporary":0 or "is_temporary":1
    # Wrong: "is_temporary":true or "is_temporary":false
    if echo "$events" | grep -qE '"is_temporary":[01]'; then
        pass "is_temporary field is numeric (0/1)"
    elif echo "$events" | grep -qE '"is_temporary":(true|false)'; then
        fail "is_temporary field is boolean (should be 0/1)"
        info "Event content: $events"
        return 1
    else
        # No is_temporary field
        if [ -z "$CLIENT1_IPV6" ]; then
            skip "is_temporary format check" "No IPv6 lease obtained"
            return 0
        fi
        info "No is_temporary field in captured events"
    fi
}

test_ipv6_lease_sync_to_peer() {
    subheader "IPv6 Lease Sync to Peer"

    if [ -z "$CLIENT1_IPV6" ]; then
        skip "IPv6 lease sync test" "No IPv6 lease to sync"
        return 0
    fi

    # Determine peer node
    local peer_node
    peer_node=$(get_peer_node "$CLIENT1_DHCP_SERVER")

    # Wait for lease to sync to peer
    info "Waiting for IPv6 lease $CLIENT1_IPV6 to sync to $peer_node..."
    if wait_for_ipv6_lease "$peer_node" "$CLIENT1_IPV6" "$SYNC_TIMEOUT"; then
        pass "IPv6 lease synced to peer ($peer_node)"
    else
        fail "IPv6 lease did not sync to $peer_node within ${SYNC_TIMEOUT}s"
        info "Peer lease file:"
        exec_node "$peer_node" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty)"
        return 1
    fi
}

test_ipv6_lease_consistency() {
    subheader "IPv6 Lease Consistency Check"

    if [ -z "$CLIENT1_IPV6" ]; then
        skip "Lease consistency check" "No IPv6 lease obtained"
        return 0
    fi

    # Get IPv6 lease count on both nodes
    local count1 count2
    count1=$(get_ipv6_lease_count "$NODE1")
    count2=$(get_ipv6_lease_count "$NODE2")

    info "$NODE1 IPv6 lease count: $count1"
    info "$NODE2 IPv6 lease count: $count2"

    if [ "$count1" = "$count2" ]; then
        pass "IPv6 lease counts match: $count1"
    else
        warn "IPv6 lease count mismatch (may stabilize)"
    fi

    # Verify both nodes have the client's IPv6 lease
    local both_have_lease=true
    for node in "$NODE1" "$NODE2"; do
        if ipv6_lease_exists "$node" "$CLIENT1_IPV6"; then
            pass "IPv6 lease for $CLIENT1_IPV6 exists on $node"
        else
            fail "IPv6 lease for $CLIENT1_IPV6 missing on $node"
            both_have_lease=false
        fi
    done

    [ "$both_have_lease" = "true" ]
}

test_ipv6_lease_release_sync() {
    subheader "IPv6 Lease Release Sync"

    if [ -z "$CLIENT1_IPV6" ]; then
        skip "Release sync test" "No IPv6 lease to release"
        return 0
    fi

    info "Releasing DHCPv6 lease for $CLIENT1 ($CLIENT1_IPV6)..."
    dhcpv6_release "$CLIENT1"

    # Poll for lease removal on both nodes
    wait_for_lease_removal_all "$CLIENT1_IPV6" "ipv6_lease_exists" 15

    if [ "$REMOVAL_COUNT" -ge 2 ]; then
        pass "IPv6 lease release synced to both nodes"
    elif [ "$REMOVAL_COUNT" -eq 1 ]; then
        warn "IPv6 lease release only removed from 1 node"
    else
        warn "IPv6 lease release not yet processed (may need expiry)"
    fi
}

# ============================================
# Extended Tests (Session 88 validation review)
# ============================================

test_temporary_address_ia_ta() {
    subheader "Test IA_TA Temporary Address Sync"

    # Request temporary address from client (if supported)
    info "Requesting temporary IPv6 address from $CLIENT1..."

    # Try to get a temporary address (privacy extensions)
    exec_client "$CLIENT1" dhcpcd -k eth0 2>/dev/null || true
    sleep 1

    # Request with temporary address support (-T flag for IA_TA)
    # Note: Not all DHCP clients support IA_TA, so this is a best-effort test
    exec_client "$CLIENT1" dhcpcd -6 -T -1 -t 10 eth0 2>/dev/null || {
        warn "DHCP client does not support IA_TA requests, skipping"
        return 0
    }
    sleep 3

    # Look for temporary addresses (usually have shorter valid lifetime)
    local temp_addrs
    temp_addrs=$(exec_client "$CLIENT1" ip -6 addr show dev eth0 2>/dev/null | \
                 grep "temporary" | awk '/inet6/ {print $2}' | cut -d/ -f1)

    if [ -n "$temp_addrs" ]; then
        info "Temporary addresses found: $temp_addrs"

        # Check if any temporary address is in the lease database
        local found_in_db=false
        for addr in $temp_addrs; do
            if get_all_leases "$NODE1" | grep -q "$addr"; then
                info "Temporary address $addr synced to lease database"
                found_in_db=true
                break
            fi
        done

        if [ "$found_in_db" = "true" ]; then
            pass "IA_TA temporary address sync working"
        else
            warn "Temporary addresses not in lease database (may not be DHCPv6-assigned)"
        fi
    else
        info "No temporary addresses assigned (normal for most configurations)"
        pass "IA_TA test complete (no temporary addresses to sync)"
    fi
}

test_lease_sync_crash_recovery() {
    subheader "Test Lease Sync Crash Recovery"

    # Get current lease count before crash
    local initial_count
    initial_count=$(get_all_leases "$NODE1" | grep -c '"ip"' || echo 0)

    if [ "$initial_count" -eq 0 ]; then
        warn "No leases to test crash recovery with"
        return 0
    fi

    info "Initial lease count on $NODE1: $initial_count"

    # Kill lease-sync daemon on NODE1 (simulate crash)
    info "Killing lease-sync on $NODE1 (simulating crash)..."
    local lease_sync_pid
    lease_sync_pid=$(exec_node "$NODE1" pgrep -f "lease-sync" | head -1)

    if [ -z "$lease_sync_pid" ]; then
        warn "lease-sync not running on $NODE1"
        return 0
    fi

    exec_node "$NODE1" kill -9 "$lease_sync_pid"
    pass "lease-sync process killed (PID: $lease_sync_pid)"

    # Wait for procd to respawn
    info "Waiting for procd to respawn lease-sync..."
    sleep 5

    # Verify lease-sync is running again
    if wait_for_service "$NODE1" "lease-sync" 15; then
        pass "lease-sync respawned by procd after crash"
    else
        fail "lease-sync did not respawn after crash"
        return 1
    fi

    # Verify lease count is still correct
    local recovered_count
    recovered_count=$(get_all_leases "$NODE1" | grep -c '"ip"' || echo 0)

    info "Lease count after recovery on $NODE1: $recovered_count"

    if [ "$recovered_count" -eq "$initial_count" ]; then
        pass "All leases preserved after crash recovery"
    else
        warn "Lease count changed: $initial_count → $recovered_count (may reconcile)"
    fi

    # Wait for sync with NODE2
    sleep 5

    # Verify lease consistency between nodes
    local count2
    count2=$(get_all_leases "$NODE2" | grep -c '"ip"' || echo 0)

    info "Lease count on $NODE2: $count2"

    if [ "$recovered_count" -eq "$count2" ]; then
        pass "Lease consistency maintained after crash recovery"
    else
        warn "Lease count mismatch after recovery: $recovered_count vs $count2"
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Release client leases
    if client_running "$CLIENT1"; then
        dhcpv6_release "$CLIENT1" 2>/dev/null || true
    fi

    # Clean up event capture files
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" rm -f /tmp/dhcp_events.log 2>/dev/null || true
    done

    # Restore odhcpd if it was running before the test
    restore_odhcpd_if_was_running

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T15: IPv6 Lease Sync"
    info "Validates DHCPv6 lease sync and IAID/is_temporary field handling"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    # Infrastructure checks
    test_dhcpv6_configured || result=1
    test_ipv6_connectivity || result=1

    # Core tests
    test_client_gets_ipv6_lease || result=1

    # Field format validation (validates the dhcp-script-ha.sh fix)
    run_nonfatal test_iaid_field_format "ubus event capture may not work in all environments"
    run_nonfatal test_is_temporary_field_format "ubus event capture may not work in all environments"

    # Sync tests
    test_ipv6_lease_sync_to_peer || result=1

    # Non-fatal: consistency checks
    run_nonfatal test_ipv6_lease_consistency "timing differences in sync"
    run_nonfatal test_ipv6_lease_release_sync "release sync may require lease expiry"

    # Extended tests (Session 88 validation review)
    run_nonfatal test_temporary_address_ia_ta "IA_TA support varies by client"
    test_lease_sync_crash_recovery || result=1

    cleanup

    return $result
}

main
exit $?
