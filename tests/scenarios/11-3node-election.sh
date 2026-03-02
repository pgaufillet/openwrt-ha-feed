#!/bin/sh
# 11-3node-election.sh - Test T11: 3-Node VRRP Election
#
# Validates correct MASTER/BACKUP assignment in a 3-node cluster.
# Requires: 3-node cluster (docker-compose.yml + docker-compose.3node.yml)
#
# Expected priorities: Node1=200 (MASTER), Node2=100 (BACKUP), Node3=50 (BACKUP)
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

test_keepalived_running_all() {
    subheader "Keepalived Running on All Nodes"
    check_service_on_all_nodes "keepalived" 30
}

test_vip_assigned() {
    subheader "VIP Assignment"

    if wait_for_vip_anywhere 30; then
        pass "VIP ($VIP_ADDRESS) assigned to $VIP_OWNER"
    else
        fail "VIP ($VIP_ADDRESS) not assigned to any node"
        for node in $(get_active_nodes); do
            info "$node IPs:"
            exec_node "$node" ip addr show 2>&1 || echo "(command failed)"
        done
        return 1
    fi
}

test_correct_master() {
    subheader "Correct MASTER Election (Highest Priority)"

    local vip_owner
    vip_owner=$(get_vip_owner)

    # Get priorities for all nodes
    local node1_priority node2_priority node3_priority
    node1_priority=$(uci_get "$NODE1" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
    node2_priority=$(uci_get "$NODE2" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
    node3_priority=$(uci_get "$NODE3" "ha-cluster.lan.priority" 2>/dev/null || echo "100")

    info "$NODE1 priority: $node1_priority"
    info "$NODE2 priority: $node2_priority"
    info "$NODE3 priority: $node3_priority"
    info "VIP owner: $vip_owner"

    # Determine expected MASTER (highest priority)
    local expected_master
    expected_master=$(get_highest_priority_node)

    if [ "$vip_owner" = "$expected_master" ]; then
        pass "Correct MASTER: $vip_owner (highest priority)"
    else
        fail "Wrong MASTER: expected $expected_master, got $vip_owner"
        return 1
    fi
}

test_backup_count() {
    subheader "BACKUP Nodes Count"

    local backup_count
    backup_count=$(count_nodes_in_state "BACKUP")

    # With 3 nodes, we expect exactly 2 BACKUPs
    if [ "$backup_count" -eq 2 ]; then
        pass "Correct BACKUP count: 2 nodes in BACKUP state"
    else
        fail "Wrong BACKUP count: expected 2, got $backup_count"
        for node in $(get_active_nodes); do
            local state
            state=$(get_vrrp_state "$node")
            info "$node: $state"
        done
        return 1
    fi
}

test_backups_no_vip() {
    subheader "BACKUP Nodes Have No VIP"

    local vip_owner
    vip_owner=$(get_vip_owner)
    local all_ok=true

    for node in $(get_active_nodes); do
        if [ "$node" = "$vip_owner" ]; then
            continue  # Skip the MASTER
        fi

        if has_vip "$node"; then
            fail "$node (BACKUP) should not have VIP"
            all_ok=false
        else
            pass "$node (BACKUP) does not have VIP"
        fi
    done

    [ "$all_ok" = "true" ]
}

test_vrrp_states() {
    subheader "VRRP States"

    local master_count=0
    local backup_count=0

    for node in $(get_active_nodes); do
        local state
        state=$(get_vrrp_state "$node")
        info "$node state: $state"

        case "$state" in
            MASTER) master_count=$((master_count + 1)) ;;
            BACKUP) backup_count=$((backup_count + 1)) ;;
        esac
    done

    # Exactly 1 MASTER, exactly 2 BACKUPs
    if [ "$master_count" -eq 1 ] && [ "$backup_count" -eq 2 ]; then
        pass "Correct states: 1 MASTER, 2 BACKUPs"
    else
        fail "Invalid states: $master_count MASTERs, $backup_count BACKUPs"
        return 1
    fi
}

test_only_one_master() {
    subheader "Single MASTER Check (No Split-Brain)"
    check_no_split_brain
}

test_priority_ordering() {
    subheader "Priority Ordering Verified"

    local node1_priority node2_priority node3_priority
    node1_priority=$(uci_get "$NODE1" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
    node2_priority=$(uci_get "$NODE2" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
    node3_priority=$(uci_get "$NODE3" "ha-cluster.lan.priority" 2>/dev/null || echo "100")

    # Expected: Node1 (200) > Node2 (100) > Node3 (50)
    if [ "$node1_priority" -gt "$node2_priority" ] && [ "$node2_priority" -gt "$node3_priority" ]; then
        pass "Priority ordering correct: $NODE1($node1_priority) > $NODE2($node2_priority) > $NODE3($node3_priority)"
    else
        warn "Priority ordering unexpected - test may not validate failover cascade correctly"
        info "Priorities: $NODE1=$node1_priority, $NODE2=$node2_priority, $NODE3=$node3_priority"
    fi
}

# ============================================
# Main
# ============================================

main() {
    header "T11: 3-Node VRRP Election"
    info "Validates correct MASTER/BACKUP assignment in 3-node cluster"

    check_3node_cluster

    test_keepalived_running_all || return 1
    test_vip_assigned || return 1
    test_correct_master || return 1
    test_backup_count || return 1
    test_backups_no_vip || return 1
    test_vrrp_states || return 1
    test_only_one_master || return 1
    test_priority_ordering || return 1

    return 0
}

main
exit $?
