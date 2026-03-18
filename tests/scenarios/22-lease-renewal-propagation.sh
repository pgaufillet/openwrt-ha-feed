#!/bin/sh
# 22-lease-renewal-propagation.sh - Test T22: Lease Renewal Propagation
#
# Validates that DHCP lease renewals update the lease expiry on the DHCP
# server AND that the updated expiry propagates to the peer via lease-sync.
#
# This test verifies the full chain:
#   client renews -> dnsmasq script-on-renewal -> dhcp-script -> lease-sync -> peer
#
# Requires: script-on-renewal in dnsmasq conf-dir overlay (ha-cluster.conf)
#
# Strategy: temporarily set a very short lease time (60s) so that dhcpcd
# naturally renews at T1 (50% = 30s). After renewal, the lease expiry
# timestamp changes and should propagate to the peer.
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

CLIENT1="ha-client1"
# Short lease time for this test (seconds). T1 renewal at 50% = 30s.
SHORT_LEASETIME="60"

# ============================================
# Helper Functions
# ============================================

# Get the expiry timestamp (first field) for a lease IP from a node
# Usage: ts=$(get_lease_expiry "ha-node1" "192.168.50.100")
get_lease_expiry() {
    local node="$1"
    local ip="$2"
    exec_node "$node" sh -c "grep '$ip' /tmp/dhcp.leases 2>/dev/null | awk '{print \$1}'" | head -1
}

# Request a fresh DHCP lease (single dhcpcd instance, daemon mode)
# Unlike the library's dhcp_request() which uses one-shot mode (-1),
# this starts dhcpcd as a persistent daemon so it can perform natural
# T1 renewal — required for the renewal propagation test.
# Outputs only the obtained IP on stdout.
# Usage: ip=$(request_fresh_lease "ha-client1")
request_fresh_lease() {
    local client="$1"

    # Kill ALL dhcpcd instances and clear state
    exec_client "$client" sh -c 'killall -9 dhcpcd 2>/dev/null || true'
    local count=0
    while [ $count -lt 5 ]; do
        if ! exec_client "$client" pgrep dhcpcd >/dev/null 2>&1; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    exec_client "$client" sh -c 'rm -rf /var/lib/dhcpcd/ 2>/dev/null || true'
    exec_client "$client" sh -c 'ip addr flush dev eth0 2>/dev/null || true'
    exec_client "$client" sh -c 'ip link set eth0 up'
    sleep 1

    # Start dhcpcd in daemon mode (stays running for natural renewal)
    exec_client "$client" sh -c 'dhcpcd -t 15 eth0 >/dev/null 2>&1' || true

    # Wait for lease
    count=0
    while [ $count -lt 15 ]; do
        local ip
        ip=$(get_client_ip "$client")
        if [ -n "$ip" ] && echo "$ip" | grep -q "^192\.168\.50\."; then
            echo "$ip"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# ============================================
# Test Setup
# ============================================

# Track original leasetime for restoration
ORIG_LEASETIME=""

setup() {
    subheader "Test Setup"

    # Check prerequisites
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            skip "Renewal propagation test" "lease-sync not running on $node"
            return 1
        fi
    done

    if ! client_running "$CLIENT1"; then
        skip "Renewal propagation test" "$CLIENT1 container not running"
        return 1
    fi

    # Verify overlay is in place (script-on-renewal required)
    local confdir
    confdir=$(exec_node "$NODE1" sh -c 'grep "^conf-dir=" /var/etc/dnsmasq.conf.* 2>/dev/null | head -1 | cut -d= -f2 | cut -d, -f1')
    if [ -z "$confdir" ] || ! exec_node "$NODE1" test -f "$confdir/ha-cluster.conf" 2>/dev/null; then
        skip "Renewal propagation test" "dnsmasq HA overlay not found (script-on-renewal required)"
        return 1
    fi

    # Save original leasetime (same on both nodes per setup.sh)
    ORIG_LEASETIME=$(uci_get "$NODE1" "dhcp.lan.leasetime" 2>/dev/null || echo "12h")

    # Set short lease time on both nodes for this test
    # Use -P to suppress procd reload trigger (we restart manually below)
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" uci set "dhcp.lan.leasetime=${SHORT_LEASETIME}s"
        exec_node "$node" uci -P /dev/null commit dhcp
    done

    # Single explicit restart to apply new leasetime
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" /etc/init.d/dnsmasq restart 2>/dev/null
    done

    # Wait for dnsmasq ubus to be ready (not just process running)
    for node in "$NODE1" "$NODE2"; do
        if ! wait_for "dnsmasq on $node" 15 "exec_node $node ubus list dnsmasq >/dev/null 2>&1"; then
            fail "dnsmasq ubus not available on $node after leasetime change"
            return 1
        fi
    done

    pass "Prerequisites met (leasetime=${SHORT_LEASETIME}s)"
    return 0
}

# ============================================
# Test Cases
# ============================================

CLIENT_IP=""
DHCP_SERVER=""

test_initial_lease() {
    subheader "Obtain Initial Lease"

    info "Requesting fresh DHCP lease for $CLIENT1..."
    CLIENT_IP=$(request_fresh_lease "$CLIENT1")

    if [ -z "$CLIENT_IP" ]; then
        fail "$CLIENT1 failed to obtain DHCP lease"
        return 1
    fi
    pass "$CLIENT1 obtained lease: $CLIENT_IP"

    # Find which node served the lease
    DHCP_SERVER=$(find_lease_server "$CLIENT_IP" "lease_exists" 10)
    if [ -z "$DHCP_SERVER" ]; then
        fail "Lease not found on any node"
        return 1
    fi
    pass "Lease served by $DHCP_SERVER"

    # Wait for initial sync to peer
    local peer
    peer=$(get_peer_node "$DHCP_SERVER")
    if wait_for_lease "$peer" "$CLIENT_IP" "$SYNC_TIMEOUT"; then
        pass "Initial lease synced to peer ($peer)"
    else
        fail "Initial lease did not sync to $peer"
        return 1
    fi
}

test_renewal_updates_expiry() {
    subheader "Renewal Updates Expiry"

    [ -z "$CLIENT_IP" ] && { fail "No lease to renew"; return 1; }

    # Record current expiry on DHCP server
    local expiry_before
    expiry_before=$(get_lease_expiry "$DHCP_SERVER" "$CLIENT_IP")
    if [ -z "$expiry_before" ]; then
        fail "Cannot read lease expiry on $DHCP_SERVER"
        return 1
    fi
    info "Expiry before renewal: $expiry_before"

    # Wait for natural renewal (T1 = 50% of lease time)
    # With 60s lease, T1 is at 30s. Add margin for processing.
    local wait_time=$(( SHORT_LEASETIME / 2 + 10 ))
    info "Waiting ${wait_time}s for natural DHCP renewal (T1=${SHORT_LEASETIME}/2)..."
    sleep "$wait_time"

    # Check expiry changed on DHCP server
    local expiry_after
    expiry_after=$(get_lease_expiry "$DHCP_SERVER" "$CLIENT_IP")

    if [ -z "$expiry_after" ]; then
        fail "Lease disappeared from $DHCP_SERVER after renewal window"
        return 1
    fi

    if [ "$expiry_after" != "$expiry_before" ]; then
        local delta=$((expiry_after - expiry_before))
        pass "Expiry updated on $DHCP_SERVER: $expiry_before -> $expiry_after (delta: ${delta}s)"
    else
        fail "Expiry did not change on $DHCP_SERVER after renewal (still $expiry_before)"
        info "This likely means script-on-renewal is not active or dhcpcd did not renew"
        # Show dnsmasq log for diagnosis
        info "Recent dnsmasq/lease-sync logs on $DHCP_SERVER:"
        exec_node "$DHCP_SERVER" sh -c "logread | grep -E 'dnsmasq|lease-sync' | tail -10" 2>/dev/null || true
        return 1
    fi
}

test_renewal_propagates_to_peer() {
    subheader "Renewal Propagates to Peer"

    [ -z "$CLIENT_IP" ] && { fail "No lease to check"; return 1; }

    local peer
    peer=$(get_peer_node "$DHCP_SERVER")

    # Get the updated expiry on DHCP server
    local server_expiry
    server_expiry=$(get_lease_expiry "$DHCP_SERVER" "$CLIENT_IP")

    # Wait for peer to get the updated expiry
    local count=0
    local peer_expiry=""
    while [ $count -lt "$SYNC_TIMEOUT" ]; do
        peer_expiry=$(get_lease_expiry "$peer" "$CLIENT_IP")
        if [ "$peer_expiry" = "$server_expiry" ]; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ "$peer_expiry" = "$server_expiry" ]; then
        pass "Peer $peer has updated expiry: $peer_expiry (matches server)"
    else
        fail "Peer expiry mismatch: server=$server_expiry, peer=${peer_expiry:-empty}"
        info "Lease on $DHCP_SERVER:"
        exec_node "$DHCP_SERVER" sh -c "grep '$CLIENT_IP' /tmp/dhcp.leases" 2>/dev/null || echo "(not found)"
        info "Lease on $peer:"
        exec_node "$peer" sh -c "grep '$CLIENT_IP' /tmp/dhcp.leases" 2>/dev/null || echo "(not found)"
        return 1
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Kill dhcpcd daemon and release client lease
    if client_running "$CLIENT1"; then
        exec_client "$CLIENT1" sh -c 'killall -9 dhcpcd 2>/dev/null || true'
        exec_client "$CLIENT1" sh -c 'ip addr flush dev eth0 2>/dev/null || true'
    fi

    # Restore original leasetime on both nodes
    local restore_leasetime="${ORIG_LEASETIME:-12h}"
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" uci set "dhcp.lan.leasetime=$restore_leasetime" 2>/dev/null || true
        exec_node "$node" uci -P /dev/null commit dhcp 2>/dev/null || true
    done

    # Single explicit restart to apply restored leasetime
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" /etc/init.d/dnsmasq restart 2>/dev/null || true
    done

    # Wait for dnsmasq to be ready before handing off to next test
    for node in "$NODE1" "$NODE2"; do
        wait_for "dnsmasq on $node" 15 "exec_node $node ubus list dnsmasq >/dev/null 2>&1" || true
    done

    pass "Cleanup complete (leasetime restored to $restore_leasetime)"
}

# ============================================
# Main
# ============================================

main() {
    header "T22: Lease Renewal Propagation"
    info "Validates renewal expiry updates propagate via lease-sync"

    local result=0

    setup || return 0
    test_initial_lease || return 1
    test_renewal_updates_expiry || result=1
    test_renewal_propagates_to_peer || result=1
    cleanup

    return $result
}

main
exit $?
