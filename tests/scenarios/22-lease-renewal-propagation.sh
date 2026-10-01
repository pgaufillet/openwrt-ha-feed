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
# Strategy: temporarily set a short lease time (120s, the minimum dnsmasq
# accepts) so that dhcpcd naturally renews at T1 (50% = 60s). After
# renewal, the lease expiry timestamp changes and should propagate to the
# peer.
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
# Short lease time for this test (seconds). dnsmasq raises anything
# shorter to 120s. T1 renewal at 50% = 60s.
SHORT_LEASETIME="120"

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

# DHCP server identifier of the client's current lease
# Usage: sid=$(get_server_id "ha-client1")
get_server_id() {
    exec_client "$1" dhcpcd -4 -U eth0 2>/dev/null | \
        sed -n 's/^dhcp_server_identifier=//p' | tr -d "'"
}

# Request a fresh DHCP lease (single dhcpcd instance, daemon mode)
# Unlike the library's dhcp_request() which uses one-shot mode (-1),
# this starts dhcpcd as a persistent daemon so it can perform natural
# T1 renewal — required for the renewal propagation test.
# With $server_ip, the client only accepts packets from it: both nodes
# offer from the same pool and the first offer wins, while the test
# follows the lease and its renewal on $server_ip.
# Outputs only the obtained IP on stdout.
# Usage: ip=$(request_fresh_lease "ha-client1" ["192.168.50.10"])
request_fresh_lease() {
    local client="$1"
    local server_ip="$2"

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
    exec_client "$client" sh -c "dhcpcd ${server_ip:+--whitelist=$server_ip} -t 15 eth0 >/dev/null 2>&1" || true

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

# Drop DHCP server traffic on a node: "input" stops it hearing clients,
# "output" stops it answering them
# Usage: block_dhcp "node" input|output
block_dhcp() {
    local match="udp dport 67"
    [ "$2" = "output" ] && match="udp sport 67"
    exec_node "$1" sh -c "nft add table inet t22_dhcp &&
        nft add chain inet t22_dhcp block '{ type filter hook $2 priority -10; }' &&
        nft add rule inet t22_dhcp block $match drop"
}

# Usage: unblock_dhcp "node"
unblock_dhcp() {
    exec_node "$1" nft delete table inet t22_dhcp >/dev/null 2>&1
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
DHCP_SERVER="$NODE1"

test_initial_lease() {
    subheader "Obtain Initial Lease"

    info "Requesting fresh DHCP lease for $CLIENT1 from $DHCP_SERVER..."
    CLIENT_IP=$(request_fresh_lease "$CLIENT1" "$NODE1_CLIENT_IP")

    if [ -z "$CLIENT_IP" ]; then
        fail "$CLIENT1 failed to obtain DHCP lease"
        return 1
    fi
    pass "$CLIENT1 obtained lease: $CLIENT_IP"

    # The lease also reaches the peer by sync: prove the server from the
    # client's server identifier, not from the lease file
    local sid
    sid=$(get_server_id "$CLIENT1")
    if [ "$sid" != "$NODE1_CLIENT_IP" ]; then
        fail "Lease not served by $DHCP_SERVER (server identifier: ${sid:-none})"
        return 1
    fi
    if wait_for_lease "$DHCP_SERVER" "$CLIENT_IP" 10; then
        pass "Lease served by $DHCP_SERVER (server identifier)"
    else
        fail "Lease not found on serving node $DHCP_SERVER"
        return 1
    fi

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

    # Poll for natural renewal (T1 = 50% of lease time) with a margin.
    # A renewal moves the expiry by about T1; ignore sync jitter.
    local wait_time=$(( SHORT_LEASETIME / 2 + 20 ))
    local min_delta=$(( SHORT_LEASETIME / 4 ))
    info "Waiting up to ${wait_time}s for natural DHCP renewal (T1=${SHORT_LEASETIME}/2)..."
    local expiry_after=""
    local count=0
    while [ $count -lt "$wait_time" ]; do
        expiry_after=$(get_lease_expiry "$DHCP_SERVER" "$CLIENT_IP")
        [ -n "$expiry_after" ] && \
            [ $((expiry_after - expiry_before)) -ge "$min_delta" ] && break
        sleep 1
        count=$((count + 1))
    done

    if [ -z "$expiry_after" ]; then
        fail "Lease disappeared from $DHCP_SERVER after renewal window"
        return 1
    fi

    local delta=$((expiry_after - expiry_before))
    if [ "$delta" -ge "$min_delta" ]; then
        pass "Expiry updated on $DHCP_SERVER: $expiry_before -> $expiry_after (delta: ${delta}s)"
    else
        fail "Expiry not renewed on $DHCP_SERVER: $expiry_before -> $expiry_after (delta: ${delta}s)"
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

# After a failover the client cannot reach its server: its renewals go
# unanswered, then it rebinds (broadcast) at T2 and the survivor, which
# holds the lease by sync, must ACK it. dnsmasq is not authoritative: a
# lease it does not know is NAKed when renewing and ignored when
# rebinding, so this is the path the synced lease exists for.
FAILED_OVER=false
VIP_OWNER=""

test_renewal_on_survivor() {
    subheader "Renewal on Survivor After Failover"

    local ip mac sid t_lease t0 deadline now result=0

    # The lease must come from NODE1, while the client must accept NODE2
    # for the rebind: silence NODE2 instead of whitelisting NODE1
    block_dhcp "$NODE2" output || { fail "Could not silence $NODE2"; return 1; }
    ip=$(request_fresh_lease "$CLIENT1")
    t_lease=$(date +%s)
    unblock_dhcp "$NODE2"
    sid=$(get_server_id "$CLIENT1")
    if [ -z "$ip" ] || [ "$sid" != "$NODE1_CLIENT_IP" ]; then
        fail "$CLIENT1 lease ${ip:-none} not served by $NODE1 (server identifier: ${sid:-none})"
        return 1
    fi
    if ! wait_for_lease "$NODE2" "$ip" "$SYNC_TIMEOUT"; then
        fail "Lease $ip did not sync to $NODE2"
        return 1
    fi
    pass "Lease $ip served by $NODE1, synced to $NODE2"

    # Fail NODE1 over as T03 does, and stop it answering DHCP
    t0=$(exec_node "$NODE2" date +%s)
    VIP_OWNER=$(get_vip_owner)
    FAILED_OVER=true
    service_stop "$NODE1" keepalived
    if ! wait_for_vip "$NODE2" "$FAILOVER_TIMEOUT"; then
        fail "VIP did not move to $NODE2"
        return 1
    fi
    block_dhcp "$NODE1" input || { fail "Could not silence $NODE1"; return 1; }
    pass "$NODE1 failed over to $NODE2 and stopped answering DHCP"

    # Rebinding starts at T2 (87.5% of the lease) and must succeed before
    # the lease expires: an expired client starts over with a DISCOVER
    deadline=$(( t_lease + SHORT_LEASETIME ))
    info "Waiting up to $(( deadline - $(date +%s) ))s for the client to rebind..."
    now=$(date +%s)
    while [ "$now" -lt "$deadline" ]; do
        sid=$(get_server_id "$CLIENT1")
        [ "$sid" = "$NODE2_CLIENT_IP" ] && break
        sleep 2
        now=$(date +%s)
    done

    if [ "$sid" = "$NODE2_CLIENT_IP" ]; then
        pass "$CLIENT1 lease now from $NODE2"
    else
        fail "$CLIENT1 not rebound to $NODE2 (server identifier: ${sid:-none})"
        result=1
    fi
    assert_eq "$ip" "$(get_client_ip "$CLIENT1")" "$CLIENT1 keeps $ip" || result=1
    mac=$(get_client_mac "$CLIENT1")
    if log_since "$NODE2" "$t0" | grep -qi "DHCPACK(.*) $ip $mac" &&
       ! log_since "$NODE2" "$t0" | grep -qi "DHCPDISCOVER(.*) $mac"; then
        pass "$NODE2 acknowledged the rebind of $ip"
    else
        fail "$NODE2 did not acknowledge a rebind of $ip"
        result=1
    fi
    if log_since "$NODE2" "$t0" | grep -q "DHCPNAK"; then
        fail "$NODE2 sent a DHCPNAK"
        log_since "$NODE2" "$t0" | grep "DHCPNAK"
        result=1
    else
        pass "$NODE2 sent no DHCPNAK"
    fi

    restore_failover || result=1
    return $result
}

# Bring NODE1 back after test_renewal_on_survivor
restore_failover() {
    [ "$FAILED_OVER" = "true" ] || return 0
    unblock_dhcp "$NODE1"
    exec_node "$NODE1" /etc/init.d/ha-cluster reload >/dev/null 2>&1
    FAILED_OVER=false
    if wait_for_service "$NODE1" keepalived 15 &&
       wait_for_vip "${VIP_OWNER:-$NODE1}" 20; then
        pass "$NODE1 back in the cluster"
    else
        fail "$NODE1 keepalived not restored"
        return 1
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    restore_failover || true
    unblock_dhcp "$NODE2"

    # Release client lease and kill dhcpcd daemon
    if client_running "$CLIENT1"; then
        exec_client "$CLIENT1" sh -c 'dhcpcd -k eth0 >/dev/null 2>&1 || true'
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
    test_initial_lease || { cleanup; return 1; }
    test_renewal_updates_expiry || result=1
    test_renewal_propagates_to_peer || result=1
    test_renewal_on_survivor || result=1
    cleanup

    return $result
}

main
exit $?
