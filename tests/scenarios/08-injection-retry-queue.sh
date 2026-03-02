#!/bin/sh
# 08-injection-retry-queue.sh - Test T08: Injection Retry Queue
#
# Validates that lease injection retries when dnsmasq is temporarily unavailable.
# The retry queue mechanism queues failed injections and retries them
# when dnsmasq becomes available again.
#
# Test uses real DHCP clients to generate representative traffic that
# triggers the full hotplug chain: dnsmasq -> dhcp-script -> hotplug ->
# lease-sync -> broadcast.
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

# Real DHCP lease will be obtained from client container
DHCP_CLIENT_MAC=""
DHCP_LEASE_IP=""
REAL_LEASE_CREATED=false

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
        skip "Retry queue test" "lease-sync not running on all nodes"
        return 1
    fi

    # Check dnsmasq is running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "dnsmasq"; then
            skip "Retry queue test" "dnsmasq not running on $node"
            return 1
        fi
    done

    # Check if DHCP client container is available
    if ! client_running "$CLIENT1"; then
        skip "Retry queue test" "DHCP client container not available"
        return 1
    fi

    # Get client MAC for later verification
    DHCP_CLIENT_MAC=$(get_client_mac "$CLIENT1")
    if [ -z "$DHCP_CLIENT_MAC" ]; then
        skip "Retry queue test" "cannot determine client MAC address"
        return 1
    fi
    info "DHCP client MAC: $DHCP_CLIENT_MAC"

    # Release any existing DHCP lease on client
    dhcp_release "$CLIENT1" 2>/dev/null || true

    # Wait for state to settle
    sleep 2

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_baseline_clean_state() {
    subheader "Verify Baseline: Clean State"

    # Release any existing client lease
    dhcp_release "$CLIENT1" 2>/dev/null || true
    sleep 2

    # Verify client MAC not in any node's lease table
    local clean=true
    for node in "$NODE1" "$NODE2"; do
        if get_all_leases "$node" | grep -qi "$DHCP_CLIENT_MAC"; then
            info "Client lease exists on $node - will be replaced"
            clean=false
        fi
    done

    if [ "$clean" = "true" ]; then
        pass "No existing client lease in cluster"
    else
        pass "Baseline checked (existing lease will be replaced)"
    fi
}

test_stop_dnsmasq_on_node2() {
    subheader "Stop dnsmasq on NODE2"

    # Stop dnsmasq on NODE2 (keep lease-sync running)
    # This simulates dnsmasq being temporarily unavailable
    info "Stopping dnsmasq on $NODE2..."
    exec_node "$NODE2" /etc/init.d/dnsmasq stop 2>/dev/null || true

    if wait_for_service_stopped "$NODE2" "dnsmasq" 10; then
        pass "dnsmasq stopped on $NODE2"
    else
        fail "dnsmasq still running on $NODE2"
        return 1
    fi

    # Verify lease-sync is still running
    if service_running "$NODE2" "lease-sync"; then
        pass "lease-sync still running on $NODE2"
    else
        fail "lease-sync also stopped (unexpected)"
        return 1
    fi
}

test_create_dhcp_lease_while_dnsmasq_down() {
    subheader "Create DHCP Lease While NODE2 dnsmasq is Down"

    # Use actual DHCP client to get a real lease from NODE1
    # This triggers the full hotplug chain on NODE1:
    # - dnsmasq grants lease
    # - dhcp-script runs (hotplug)
    # - lease-sync broadcasts to NODE2
    # - NODE2's lease-sync receives but can't inject (dnsmasq down)
    # - Lease is queued for retry

    info "Requesting DHCP lease from $CLIENT1..."

    DHCP_LEASE_IP=$(dhcp_request "$CLIENT1")
    if [ -z "$DHCP_LEASE_IP" ]; then
        fail "Failed to obtain DHCP lease"
        return 1
    fi
    pass "DHCP lease obtained: $DHCP_LEASE_IP"

    # Wait for lease to appear on NODE1
    info "Verifying lease on $NODE1..."
    if wait_for_dhcp_lease_by_mac "$NODE1" "$DHCP_CLIENT_MAC" 10; then
        pass "Lease for $DHCP_CLIENT_MAC present on $NODE1"
    else
        fail "Lease not found on $NODE1"
        return 1
    fi

    REAL_LEASE_CREATED=true
}

test_verify_retry_queue_activity() {
    subheader "Verify Retry Queue Activity"

    # Give lease-sync on NODE2 time to receive the broadcast and queue it
    info "Waiting for lease-sync to receive broadcast and queue for retry..."
    sleep 5

    # Check logs for retry queue indication
    local log_output
    log_output=$(exec_node "$NODE2" logread 2>/dev/null | grep -i "lease-sync" | tail -30 || echo "")

    # Look for patterns indicating retry queue activity
    # When dnsmasq is unavailable, lease-sync should log something like:
    # "Failed to inject lease, queuing for retry" or similar
    if echo "$log_output" | grep -qi "queue\|retry\|failed.*inject"; then
        pass "Retry queue activity detected in logs"
        info "Log excerpt:"
        echo "$log_output" | grep -i "queue\|retry\|failed" | head -5
    else
        info "No explicit retry queue log found - may use different logging"
        info "Recent lease-sync logs:"
        echo "$log_output" | tail -10
    fi
}

test_lease_not_on_node2_yet() {
    subheader "Verify Lease Not on NODE2 (dnsmasq down)"

    # The lease should NOT be in NODE2's dnsmasq because dnsmasq is stopped
    if get_all_leases "$NODE2" 2>/dev/null | grep -qi "$DHCP_CLIENT_MAC"; then
        info "Lease appears in NODE2 ubus (unexpected - dnsmasq should be down)"
        # This shouldn't happen if dnsmasq is truly down
        return 1
    else
        pass "Lease not in NODE2 (expected - dnsmasq down)"
    fi
}

test_restart_dnsmasq() {
    subheader "Restart dnsmasq on NODE2"

    info "Starting dnsmasq on $NODE2..."
    exec_node "$NODE2" /etc/init.d/dnsmasq start 2>/dev/null || true

    if wait_for_service "$NODE2" "dnsmasq" 15; then
        pass "dnsmasq restarted on $NODE2"
    else
        fail "dnsmasq failed to restart on $NODE2"
        return 1
    fi

    # Give dnsmasq time to initialize ubus interface
    sleep 2

    # Give lease-sync time to process retry queue
    # lease-sync retries every RETRY_INTERVAL_SECONDS (default 5s)
    info "Waiting for retry queue to be processed..."
    sleep 12
}

test_lease_injected_from_queue() {
    subheader "Verify Queued Lease Injected After Retry"

    if [ "$REAL_LEASE_CREATED" = "false" ]; then
        skip "Retry queue verification" "DHCP lease was not created"
        return 0
    fi

    # After dnsmasq restarts, lease-sync should retry and inject the queued lease
    info "Checking if lease was injected from retry queue..."

    if wait_for_dhcp_lease_by_mac "$NODE2" "$DHCP_CLIENT_MAC" 20; then
        pass "Lease present on $NODE2 (retry queue worked)"
    else
        fail "Lease not found on $NODE2 (retry queue may have failed)"
        info "NODE2 ubus leases:"
        get_all_leases "$NODE2"
        info "NODE2 lease-sync logs:"
        exec_node "$NODE2" logread 2>/dev/null | grep -i "lease-sync" | tail -20 || true
        return 1
    fi
}

test_verify_final_consistency() {
    subheader "Verify Final Cluster Consistency"

    local consistent=true

    # Both nodes should have the lease
    if [ "$REAL_LEASE_CREATED" = "true" ]; then
        for node in "$NODE1" "$NODE2"; do
            if get_all_leases "$node" | grep -qi "$DHCP_CLIENT_MAC"; then
                pass "Lease present on $node"
            else
                fail "Lease missing from $node"
                consistent=false
            fi
        done

        if [ "$consistent" = "true" ]; then
            pass "Cluster is consistent - lease present on both nodes"
        fi
    else
        skip "Lease consistency check" "DHCP lease was not created"
    fi

    [ "$consistent" = "true" ]
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Release DHCP lease from client
    if [ "$REAL_LEASE_CREATED" = "true" ]; then
        info "Releasing DHCP lease from $CLIENT1..."
        dhcp_release "$CLIENT1" 2>/dev/null || true
    fi

    # Ensure dnsmasq is running on both nodes
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "dnsmasq"; then
            info "Restarting dnsmasq on $node..."
            exec_node "$node" /etc/init.d/dnsmasq start 2>/dev/null || true
        fi
    done

    # Ensure lease-sync is running on both nodes
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
        fi
    done

    # Wait for cleanup to settle
    sleep 2

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T08: Injection Retry Queue"
    info "Validates lease injection retries when dnsmasq unavailable"
    info "Uses real DHCP clients for representative testing"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    test_baseline_clean_state || result=1
    test_stop_dnsmasq_on_node2 || result=1
    test_create_dhcp_lease_while_dnsmasq_down || result=1
    test_verify_retry_queue_activity  # Non-fatal - logging may vary
    test_lease_not_on_node2_yet || result=1
    test_restart_dnsmasq || result=1
    test_lease_injected_from_queue || result=1
    test_verify_final_consistency || result=1

    cleanup

    return $result
}

main
exit $?
