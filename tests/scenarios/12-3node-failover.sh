#!/bin/sh
# 12-3node-failover.sh - Test T12: 3-Node Failover Cascade
#
# Tests VIP failover cascade through all 3 nodes based on priority ordering.
# Requires: 3-node cluster (docker-compose.yml + docker-compose.3node.yml)
#
# Expected failover chain: Node1 (200) -> Node2 (100) -> Node3 (50)
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
# Pre-flight Check
# ============================================

check_3node_cluster() {
    if ! node_running "$NODE3"; then
        skip "Node3 not running - this test requires a 3-node cluster"
        info "Start with: docker compose -f docker-compose.yml -f docker-compose.3node.yml up -d"
        exit 0
    fi
}

# ============================================
# Test Cases
# ============================================

test_initial_state() {
    subheader "Initial State Verification"

    # Wait for cluster to stabilize
    if ! wait_for_cluster_healthy 30; then
        fail "Cluster not healthy at start"
        print_cluster_status
        return 1
    fi

    # Verify initial MASTER
    local vip_owner expected_master
    vip_owner=$(get_vip_owner)
    expected_master=$(get_highest_priority_node)

    if [ "$vip_owner" = "$expected_master" ]; then
        pass "Initial MASTER is $vip_owner (highest priority)"
    else
        fail "Initial MASTER should be $expected_master, got $vip_owner"
        return 1
    fi
}

test_first_failover() {
    subheader "First Failover: MASTER -> Secondary"

    local initial_master
    initial_master=$(get_vip_owner)
    local expected_secondary
    expected_secondary=$(get_second_priority_node)

    info "Stopping keepalived on $initial_master"
    service_stop "$initial_master" "keepalived"

    # Wait for failover
    if wait_for_vip "$expected_secondary" "$FAILOVER_TIMEOUT"; then
        pass "VIP moved to $expected_secondary (first failover)"
    else
        local new_owner
        new_owner=$(get_vip_owner)
        fail "VIP should have moved to $expected_secondary, but is on ${new_owner:-none}"
        return 1
    fi

    # Verify only one MASTER
    check_no_split_brain || return 1
}

test_second_failover() {
    subheader "Second Failover: Secondary -> Tertiary"

    local current_master
    current_master=$(get_vip_owner)

    # Node3 should be the only remaining node with keepalived
    info "Stopping keepalived on $current_master"
    service_stop "$current_master" "keepalived"

    # Wait for failover to Node3
    if wait_for_vip "$NODE3" "$FAILOVER_TIMEOUT"; then
        pass "VIP moved to $NODE3 (second failover - last resort)"
    else
        local new_owner
        new_owner=$(get_vip_owner)
        fail "VIP should have moved to $NODE3, but is on ${new_owner:-none}"
        return 1
    fi

    # Node3 should now be MASTER (even with lowest priority, it's the only one)
    local node3_state
    node3_state=$(get_vrrp_state "$NODE3")
    if [ "$node3_state" = "MASTER" ]; then
        pass "$NODE3 is MASTER (only remaining node)"
    else
        fail "$NODE3 should be MASTER, but is $node3_state"
        return 1
    fi
}

test_recovery_cascade() {
    subheader "Recovery Cascade: Tertiary -> Secondary -> Primary"

    # Get expected order based on priorities
    local highest_node secondary_node
    highest_node=$(get_highest_priority_node)
    secondary_node=$(get_second_priority_node)

    # Restart secondary node (should preempt Node3 if nopreempt is not set)
    info "Restarting keepalived on $secondary_node"
    service_start "$secondary_node" "keepalived"

    # Wait for keepalived to start
    if ! wait_for_service "$secondary_node" "keepalived" 10; then
        fail "Keepalived failed to start on $secondary_node"
        return 1
    fi

    # Wait for VRRP to stabilize
    sleep 5

    # Check if secondary took over (depends on preempt setting)
    local current_owner
    current_owner=$(get_vip_owner)
    info "After secondary restart, VIP owner: $current_owner"

    # Now restart highest priority node
    info "Restarting keepalived on $highest_node"
    service_start "$highest_node" "keepalived"

    if ! wait_for_service "$highest_node" "keepalived" 10; then
        fail "Keepalived failed to start on $highest_node"
        return 1
    fi

    # Wait for VRRP to stabilize
    sleep 5

    # Final state check
    current_owner=$(get_vip_owner)
    info "After highest priority restart, VIP owner: $current_owner"

    # At minimum, we should have no split-brain
    check_no_split_brain || return 1

    pass "Recovery cascade completed"
}

test_final_state() {
    subheader "Final State Verification"

    # All nodes should have keepalived running
    local all_running=true
    for node in $(get_active_nodes); do
        if service_running "$node" "keepalived"; then
            pass "Keepalived running on $node"
        else
            fail "Keepalived not running on $node"
            all_running=false
        fi
    done

    [ "$all_running" = "true" ] || return 1

    # Check VRRP states
    local master_count backup_count
    master_count=$(count_nodes_in_state "MASTER")
    backup_count=$(count_nodes_in_state "BACKUP")

    if [ "$master_count" -eq 1 ] && [ "$backup_count" -eq 2 ]; then
        pass "Correct final state: 1 MASTER, 2 BACKUPs"
    else
        fail "Wrong final state: $master_count MASTERs, $backup_count BACKUPs"
        print_cluster_status
        return 1
    fi

    # Verify no split-brain
    check_no_split_brain
}

# ============================================
# Main
# ============================================

main() {
    header "T12: 3-Node Failover Cascade"
    info "Tests VIP failover through all nodes based on priority"

    check_3node_cluster

    test_initial_state || return 1
    test_first_failover || return 1
    test_second_failover || return 1
    test_recovery_cascade || return 1
    test_final_state || return 1

    return 0
}

main
exit $?
