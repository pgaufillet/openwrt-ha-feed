#!/bin/sh
# 07-startup-reconciliation.sh - Test T07: Startup Reconciliation
#
# Validates that stale leases are deleted when lease-sync restarts.
# The startup reconciliation mechanism ensures that leases not known
# to peers are cleaned up during startup.
#
# Test flow:
#   1. Create real DHCP lease (syncs to both nodes while lease-sync running)
#   2. Stop lease-sync on NODE2
#   3. Stop dnsmasq on NODE2, inject stale lease to dhcp.leases file
#   4. Start dnsmasq on NODE2 (loads stale lease into memory)
#   5. Restart lease-sync on NODE2 (triggers startup reconciliation)
#   6. Verify: stale lease deleted, real lease preserved
#
# IMPORTANT: The real DHCP lease must be created BEFORE stopping lease-sync.
# Otherwise, with two dnsmasq instances running, either could respond to
# DHCPDISCOVER. If NODE2 responds, the lease only exists there and
# reconciliation correctly deletes it (not known to peers).
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

# Stale lease (injected directly, not known to peers)
STALE_LEASE_IP="192.168.50.200"
STALE_LEASE_MAC="aa:bb:cc:dd:ee:01"

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
        skip "Startup reconciliation test" "lease-sync not running on all nodes"
        return 1
    fi

    # Check if DHCP client container is available
    if ! client_running "$CLIENT1"; then
        skip "Startup reconciliation test" "DHCP client container not available"
        return 1
    fi

    # Get client MAC for later verification
    DHCP_CLIENT_MAC=$(get_client_mac "$CLIENT1")
    if [ -z "$DHCP_CLIENT_MAC" ]; then
        skip "Startup reconciliation test" "cannot determine client MAC address"
        return 1
    fi
    info "DHCP client MAC: $DHCP_CLIENT_MAC"

    # Clear any existing stale test lease
    delete_lease "$NODE1" "$STALE_LEASE_IP" 2>/dev/null || true
    delete_lease "$NODE2" "$STALE_LEASE_IP" 2>/dev/null || true

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

    # Verify stale lease IP not present
    if get_all_leases "$NODE1" | grep -q "\"$STALE_LEASE_IP\""; then
        info "Stale lease IP exists on $NODE1 - cleaning up"
        delete_lease "$NODE1" "$STALE_LEASE_IP" 2>/dev/null || true
    fi
    if get_all_leases "$NODE2" | grep -q "\"$STALE_LEASE_IP\""; then
        info "Stale lease IP exists on $NODE2 - cleaning up"
        delete_lease "$NODE2" "$STALE_LEASE_IP" 2>/dev/null || true
    fi

    pass "Baseline state verified"
}

test_create_real_dhcp_lease() {
    subheader "Create Real DHCP Lease via Client"

    # IMPORTANT: Create the DHCP lease BEFORE stopping lease-sync on NODE2!
    # This ensures the lease syncs to both nodes first.
    # If we created it after stopping lease-sync, one of two things would happen:
    # - If NODE1 responds: lease only on NODE1, never synced to NODE2
    # - If NODE2 responds: lease only on NODE2, reconciliation correctly deletes it (not known to peers)

    info "Requesting DHCP lease from $CLIENT1..."
    DHCP_LEASE_IP=$(dhcp_request "$CLIENT1")
    if [ -z "$DHCP_LEASE_IP" ]; then
        fail "Failed to obtain DHCP lease"
        return 1
    fi
    pass "DHCP lease obtained: $DHCP_LEASE_IP"

    # Wait for lease to appear on both nodes (synced via lease-sync)
    info "Verifying lease synced to both nodes..."

    if wait_for_dhcp_lease_by_mac "$NODE1" "$DHCP_CLIENT_MAC" 10; then
        pass "Lease for $DHCP_CLIENT_MAC present on $NODE1"
    else
        fail "Lease not found on $NODE1"
        return 1
    fi

    if wait_for_dhcp_lease_by_mac "$NODE2" "$DHCP_CLIENT_MAC" 10; then
        pass "Lease for $DHCP_CLIENT_MAC synced to $NODE2"
    else
        fail "Lease not synced to $NODE2 (lease-sync issue)"
        return 1
    fi

    REAL_LEASE_CREATED=true
}

test_stop_lease_sync_on_node2() {
    subheader "Stop lease-sync on NODE2"

    info "Stopping lease-sync on $NODE2..."
    if service_stop "$NODE2" "lease-sync"; then
        pass "lease-sync stopped on $NODE2"
    else
        fail "Failed to stop lease-sync on $NODE2"
        return 1
    fi

    # Verify it's stopped
    sleep 1
    if service_running "$NODE2" "lease-sync"; then
        fail "lease-sync still running on $NODE2"
        return 1
    fi
    pass "Verified lease-sync stopped"
}

test_stop_dnsmasq_on_node2() {
    subheader "Stop dnsmasq on NODE2"

    # dnsmasq is the sole owner of /tmp/dhcp.leases - it periodically rewrites
    # the file from its internal state. We must stop dnsmasq before injecting
    # a stale lease, otherwise dnsmasq will overwrite our injection.
    info "Stopping dnsmasq on $NODE2..."
    exec_node "$NODE2" /etc/init.d/dnsmasq stop 2>/dev/null || true

    if wait_for_service_stopped "$NODE2" "dnsmasq" 10; then
        pass "dnsmasq stopped on $NODE2"
    else
        fail "dnsmasq still running on $NODE2"
        return 1
    fi
}

test_inject_stale_lease() {
    subheader "Inject Stale Lease on NODE2"

    # Inject lease directly to NODE2's dhcp.leases file (bypasses lease-sync)
    # This simulates a stale lease from before the node was isolated
    info "Injecting stale lease ($STALE_LEASE_IP) directly to $NODE2..."
    inject_lease_directly "$NODE2" "$STALE_LEASE_IP" "$STALE_LEASE_MAC" "stale-host" 7200

    # Verify the stale lease is in the file
    if lease_exists "$NODE2" "$STALE_LEASE_IP"; then
        pass "Stale lease injected on $NODE2"
    else
        fail "Failed to inject stale lease on $NODE2"
        return 1
    fi

    # Verify NODE1 does NOT have this lease
    if get_all_leases "$NODE1" | grep -q "\"$STALE_LEASE_IP\""; then
        fail "Stale lease unexpectedly present on $NODE1"
        return 1
    fi
    pass "Stale lease not present on $NODE1 (as expected)"
}

test_start_dnsmasq_on_node2() {
    subheader "Start dnsmasq on NODE2"

    # Start dnsmasq - it will read the dhcp.leases file on startup,
    # loading our injected stale lease into its internal state
    info "Starting dnsmasq on $NODE2..."
    exec_node "$NODE2" /etc/init.d/dnsmasq start 2>/dev/null || true

    if wait_for_service "$NODE2" "dnsmasq" 15; then
        pass "dnsmasq started on $NODE2"
    else
        fail "dnsmasq failed to start on $NODE2"
        return 1
    fi

    # Wait for dnsmasq to load the stale lease from dhcp.leases file
    # dnsmasq reads the lease file asynchronously after startup, so we
    # need to poll until the stale lease appears in ubus state
    info "Waiting for dnsmasq to load stale lease from file..."
    if wait_for_ubus_lease "$NODE2" "$STALE_LEASE_IP" 15; then
        pass "Stale lease present in dnsmasq state (via ubus)"
    else
        fail "Stale lease not loaded by dnsmasq within timeout"
        info "dnsmasq ubus leases on $NODE2:"
        get_all_leases "$NODE2"
        return 1
    fi
}


test_restart_lease_sync() {
    subheader "Restart lease-sync on NODE2"

    # Restart lease-sync on NODE2 - this triggers startup reconciliation
    info "Restarting lease-sync on $NODE2..."

    # Use ha-cluster to restart (ensures proper procd registration)
    exec_node "$NODE2" /etc/init.d/ha-cluster restart 2>/dev/null || true

    if wait_for_service "$NODE2" "lease-sync" 15; then
        pass "lease-sync restarted on $NODE2"
    else
        fail "lease-sync failed to restart on $NODE2"
        return 1
    fi

    # Give startup reconciliation time to complete
    # lease-sync queries peers on startup and reconciles local state
    info "Waiting for startup reconciliation..."
    sleep 8
}

test_stale_lease_deleted() {
    subheader "Verify Stale Lease Deleted"

    # The stale lease should be deleted because NODE1 doesn't know about it
    # lease-sync queries peers on startup and deletes any local-only leases

    info "Checking if stale lease was deleted from $NODE2 (via ubus)..."

    if wait_for_ubus_lease_absent "$NODE2" "$STALE_LEASE_IP" 15; then
        pass "Stale lease deleted from $NODE2 (reconciliation working)"
    else
        fail "Stale lease still present on $NODE2 (reconciliation failed)"
        info "NODE2 ubus leases:"
        get_all_leases "$NODE2"
        return 1
    fi
}

test_real_lease_synced() {
    subheader "Verify Real DHCP Lease Still Present on NODE2"

    if [ "$REAL_LEASE_CREATED" = "false" ]; then
        skip "Real lease verification" "DHCP lease was not created"
        return 0
    fi

    # The real DHCP lease was synced to NODE2 BEFORE we stopped lease-sync.
    # Reconciliation should have kept it because it's known to peers (via SYNC_RESPONSE).
    # This verifies reconciliation correctly distinguishes stale (delete) from valid (keep).

    info "Checking real DHCP lease still present on $NODE2..."

    if wait_for_dhcp_lease_by_mac "$NODE2" "$DHCP_CLIENT_MAC" 10; then
        pass "Real DHCP lease preserved on $NODE2 (reconciliation kept valid lease)"
    else
        fail "Real DHCP lease missing from $NODE2 (reconciliation incorrectly deleted it)"
        info "NODE2 ubus leases:"
        get_all_leases "$NODE2"
        return 1
    fi
}

test_verify_consistency() {
    subheader "Verify Final Cluster State Consistency"

    local consistent=true

    # Both nodes should have the real DHCP lease
    if [ "$REAL_LEASE_CREATED" = "true" ]; then
        for node in "$NODE1" "$NODE2"; do
            if get_all_leases "$node" | grep -qi "$DHCP_CLIENT_MAC"; then
                pass "Real lease present on $node"
            else
                fail "Real lease missing from $node"
                consistent=false
            fi
        done
    else
        skip "Real lease consistency check" "DHCP lease was not created"
    fi

    # Neither node should have the stale lease
    for node in "$NODE1" "$NODE2"; do
        if get_all_leases "$node" | grep -q "\"$STALE_LEASE_IP\""; then
            fail "Stale lease still on $node"
            consistent=false
        else
            pass "Stale lease absent from $node"
        fi
    done

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

    # Remove stale lease if still present
    delete_lease "$NODE1" "$STALE_LEASE_IP" 2>/dev/null || true
    delete_lease "$NODE2" "$STALE_LEASE_IP" 2>/dev/null || true

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
    header "T07: Startup Reconciliation"
    info "Validates stale leases are deleted when node recovers"
    info "Uses real DHCP clients for representative testing"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    # Step 1: Establish baseline and create real lease BEFORE isolation
    test_baseline_clean_state || result=1
    test_create_real_dhcp_lease || result=1  # Must be before stopping lease-sync!

    # Step 2: Isolate NODE2 and inject stale lease
    test_stop_lease_sync_on_node2 || result=1
    test_stop_dnsmasq_on_node2 || result=1
    test_inject_stale_lease || result=1
    test_start_dnsmasq_on_node2 || result=1

    # Step 3: Restart lease-sync and verify startup reconciliation
    test_restart_lease_sync || result=1
    test_stale_lease_deleted || result=1
    test_real_lease_synced || result=1
    test_verify_consistency || result=1

    cleanup

    return $result
}

main
exit $?
