#!/bin/sh
# 03-vrrp-failover.sh - Test T03: VIP Failover
#
# Validates VIP migrates to BACKUP when MASTER fails.
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

    # Ensure both nodes are running ha-cluster
    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" 2>/dev/null || true
    done

    # Wait for cluster to stabilize
    if ! wait_for_cluster_healthy 45; then
        fail "Cluster not healthy for failover test"
        return 1
    fi

    pass "Cluster healthy"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_initial_state() {
    subheader "Initial State"

    local vip_owner
    vip_owner=$(get_vip_owner)

    if [ -z "$vip_owner" ]; then
        fail "No initial MASTER found"
        return 1
    fi

    pass "Initial MASTER: $vip_owner"
    echo "$vip_owner"  # Return for use in later tests
}

test_failover() {
    subheader "Failover Test"

    # Get current master
    local original_master new_master
    original_master=$(get_vip_owner)

    if [ -z "$original_master" ]; then
        fail "Cannot determine current MASTER"
        return 1
    fi

    # Determine the backup node
    local backup_node
    if [ "$original_master" = "$NODE1" ]; then
        backup_node="$NODE2"
    else
        backup_node="$NODE1"
    fi

    info "Original MASTER: $original_master"
    info "Expected new MASTER: $backup_node"

    # Stop keepalived on current MASTER
    info "Stopping keepalived on $original_master..."
    service_stop "$original_master" "keepalived"

    # Wait for failover
    info "Waiting for failover..."
    local start_time end_time failover_time
    start_time=$(date +%s)

    if wait_for_vip "$backup_node" "$FAILOVER_TIMEOUT"; then
        end_time=$(date +%s)
        failover_time=$((end_time - start_time))
        pass "VIP failover completed in ${failover_time}s"
    else
        fail "VIP did not failover to $backup_node within ${FAILOVER_TIMEOUT}s"
        return 1
    fi

    # Verify new MASTER
    new_master=$(get_vip_owner)
    if [ "$new_master" = "$backup_node" ]; then
        pass "New MASTER is $backup_node"
    else
        fail "Unexpected MASTER: $new_master (expected $backup_node)"
        return 1
    fi

    # Verify old MASTER no longer has VIP
    if ! has_vip "$original_master"; then
        pass "Old MASTER ($original_master) no longer has VIP"
    else
        fail "Old MASTER ($original_master) still has VIP (split-brain?)"
        return 1
    fi
}

test_recovery() {
    subheader "Recovery Test"

    # Get current state
    local current_master
    current_master=$(get_vip_owner)

    if [ -z "$current_master" ]; then
        fail "No MASTER found after failover"
        return 1
    fi

    # Determine which node is down
    local down_node
    if [ "$current_master" = "$NODE1" ]; then
        down_node="$NODE2"
    else
        down_node="$NODE1"
    fi

    info "Current MASTER: $current_master"
    info "Restarting keepalived on: $down_node"

    # Restart keepalived on the down node
    service_start "$down_node" "keepalived"

    # Wait for it to start
    if ! wait_for_service "$down_node" "keepalived" 15; then
        fail "keepalived failed to start on $down_node"
        return 1
    fi

    # Give VRRP time to start advertising before checking state
    # This prevents checking during the initial VRRP transition
    sleep 3

    # Wait for VRRP to stabilize - poll until exactly one node has VIP
    wait_for_vrrp_stable 20

    # Fail if VIP not assigned after recovery
    if ! has_vip "$NODE1" && ! has_vip "$NODE2"; then
        if ! wait_for_vip_anywhere 10; then
            fail "VIP not assigned to any node after recovery"
            return 1
        fi
    fi

    # Check that cluster is stable (no split-brain)
    if ! check_no_split_brain; then
        return 1
    fi

    local final_master
    final_master=$(get_vip_owner)
    pass "Cluster stable after recovery: MASTER is $final_master"

    # Note: Preemption behavior depends on configuration
    local nopreempt
    nopreempt=$(uci_get "$down_node" "ha-cluster.lan.nopreempt" 2>/dev/null || echo "0")
    if [ "$nopreempt" = "1" ]; then
        info "Note: Preemption disabled, VIP may not return to original MASTER"
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Ensure both nodes have keepalived running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "keepalived"; then
            info "Restarting keepalived on $node"
            service_start "$node" "keepalived" 2>/dev/null || true
        fi
    done

    # Wait for cluster to restabilize using event-based polling
    if ! wait_for_cluster_healthy 15 >/dev/null 2>&1; then
        warn "Cluster did not fully restabilize after test"
    fi
    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T03: VIP Failover"
    info "Validates VIP migrates on MASTER failure"

    local result=0

    setup || return 1
    test_initial_state || return 1
    test_failover || result=1
    test_recovery || result=1
    cleanup

    return $result
}

main
exit $?
