#!/bin/sh
# 06-service-recovery.sh - Test T06: Service Crash Recovery
#
# Validates that procd correctly respawns crashed services and that the
# cluster recovers gracefully from service failures.
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
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Ensure cluster is healthy before starting
    if ! wait_for_cluster_healthy 30; then
        skip "Cluster not healthy" "cannot test service recovery"
        return 1
    fi

    pass "Test setup complete - cluster is healthy"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_keepalived_respawn() {
    subheader "Keepalived Respawn After SIGKILL"

    # Record which node has VIP before crash
    local vip_owner_before
    vip_owner_before=$(get_vip_owner)
    info "VIP owner before crash: $vip_owner_before"

    # Kill keepalived on NODE1 with SIGKILL
    info "Killing keepalived on $NODE1 with SIGKILL..."
    if ! kill_process "$NODE1" "keepalived" "SIGKILL"; then
        fail "Could not kill keepalived on $NODE1"
        return 1
    fi

    # Verify it's dead
    sleep 1
    if service_running "$NODE1" "keepalived"; then
        fail "keepalived still running after SIGKILL"
        return 1
    fi
    pass "keepalived killed on $NODE1"

    # Wait for procd to respawn it
    info "Waiting for procd to respawn keepalived..."
    if wait_for_respawn "$NODE1" "keepalived" 10; then
        pass "keepalived respawned by procd within 10s"
    else
        fail "keepalived did not respawn within 10s"
        return 1
    fi

    # Verify cluster reconverges
    if wait_for_cluster_healthy 15; then
        pass "Cluster healthy after keepalived respawn"
    else
        fail "Cluster did not recover after keepalived respawn"
        return 1
    fi
}

test_owsync_respawn() {
    subheader "Owsync Respawn After SIGKILL"

    # Check if owsync is running
    if ! service_running "$NODE1" "owsync"; then
        skip "owsync respawn" "owsync not running on $NODE1"
        return 0
    fi

    # Kill owsync with SIGKILL
    info "Killing owsync on $NODE1 with SIGKILL..."
    if ! kill_process "$NODE1" "owsync" "SIGKILL"; then
        fail "Could not kill owsync on $NODE1"
        return 1
    fi

    # Verify it's dead
    sleep 1
    if service_running "$NODE1" "owsync"; then
        fail "owsync still running after SIGKILL"
        return 1
    fi
    pass "owsync killed on $NODE1"

    # Wait for procd to respawn it
    info "Waiting for procd to respawn owsync..."
    if wait_for_respawn "$NODE1" "owsync" 10; then
        pass "owsync respawned by procd within 10s"
    else
        fail "owsync did not respawn within 10s"
        return 1
    fi
}

test_lease_sync_respawn() {
    subheader "Lease-sync Respawn After SIGKILL"

    # Check if lease-sync is running
    if ! service_running "$NODE1" "lease-sync"; then
        skip "lease-sync respawn" "lease-sync not running on $NODE1"
        return 0
    fi

    # Kill lease-sync with SIGKILL
    info "Killing lease-sync on $NODE1 with SIGKILL..."
    if ! kill_process "$NODE1" "lease-sync" "SIGKILL"; then
        fail "Could not kill lease-sync on $NODE1"
        return 1
    fi

    # Verify it's dead
    sleep 1
    if service_running "$NODE1" "lease-sync"; then
        fail "lease-sync still running after SIGKILL"
        return 1
    fi
    pass "lease-sync killed on $NODE1"

    # Wait for procd to respawn it
    info "Waiting for procd to respawn lease-sync..."
    if wait_for_respawn "$NODE1" "lease-sync" 10; then
        pass "lease-sync respawned by procd within 10s"
    else
        fail "lease-sync did not respawn within 10s"
        return 1
    fi
}

test_vip_failover_during_crash() {
    subheader "VIP Failover During Keepalived Crash"

    # Ensure NODE1 has VIP first by restarting the cluster
    # (If NODE1 is MASTER, this test is more meaningful)
    local initial_owner
    initial_owner=$(get_vip_owner)
    info "Initial VIP owner: $initial_owner"

    if [ "$initial_owner" != "$NODE1" ]; then
        info "VIP not on $NODE1, test will verify failover to $NODE1"
    fi

    # Kill keepalived on the current VIP owner
    info "Killing keepalived on VIP owner ($initial_owner)..."
    if ! kill_process "$initial_owner" "keepalived" "SIGKILL"; then
        fail "Could not kill keepalived on $initial_owner"
        return 1
    fi

    # Determine expected failover target
    local failover_target
    if [ "$initial_owner" = "$NODE1" ]; then
        failover_target="$NODE2"
    else
        failover_target="$NODE1"
    fi

    # Wait for VIP to move to the other node
    info "Waiting for VIP to failover to $failover_target..."
    if wait_for_vip "$failover_target" 10; then
        pass "VIP failed over to $failover_target"
    else
        fail "VIP did not failover to $failover_target"
        return 1
    fi

    # Wait for keepalived to respawn on original owner
    info "Waiting for keepalived to respawn on $initial_owner..."
    if wait_for_respawn "$initial_owner" "keepalived" 10; then
        pass "keepalived respawned on $initial_owner"
    else
        fail "keepalived did not respawn on $initial_owner"
        return 1
    fi

    # Verify cluster is healthy (no split-brain)
    sleep 2  # Allow VRRP to stabilize
    if check_no_split_brain; then
        pass "No split-brain after recovery"
    else
        return 1
    fi
}

test_no_state_corruption() {
    subheader "No State Corruption After Recovery"

    # Verify all services running on both nodes
    local all_ok=true

    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "keepalived"; then
            fail "keepalived not running on $node after recovery"
            all_ok=false
        fi
    done

    if [ "$all_ok" = "true" ]; then
        pass "All keepalived instances running"
    fi

    # Verify VIP is assigned to exactly one node
    check_no_split_brain || return 1

    # Verify nodes can communicate
    if nodes_can_communicate; then
        pass "Nodes can communicate after recovery"
    else
        fail "Nodes cannot communicate after recovery"
        return 1
    fi

    pass "No state corruption detected"
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Ensure all services are running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "keepalived"; then
            info "Restarting ha-cluster on $node..."
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
        fi
    done

    # Wait for cluster to stabilize
    wait_for_cluster_healthy 15 || true

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T06: Service Crash Recovery"
    info "Validates procd respawns crashed services correctly"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    test_keepalived_respawn || result=1
    test_owsync_respawn || result=1
    test_lease_sync_respawn || result=1
    test_vip_failover_during_crash || result=1
    test_no_state_corruption || result=1

    cleanup

    return $result
}

main
exit $?
