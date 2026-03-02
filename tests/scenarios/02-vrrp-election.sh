#!/bin/sh
# 02-vrrp-election.sh - Test T02: VRRP Election
#
# Validates correct MASTER/BACKUP assignment based on priorities.
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
# Test Cases
# ============================================

test_keepalived_running_both() {
    subheader "Keepalived Running on Both Nodes"
    check_service_on_all_nodes "keepalived" 30
}

test_vip_assigned() {
    subheader "VIP Assignment"

    # Wait for VIP to be assigned somewhere (sets VIP_OWNER variable)
    if wait_for_vip_anywhere 30; then
        pass "VIP ($VIP_ADDRESS) assigned to $VIP_OWNER"
    else
        fail "VIP ($VIP_ADDRESS) not assigned to any node"
        info "Node1 IPs:"
        exec_node "$NODE1" ip addr show 2>&1 || echo "(command failed)"
        info "Node2 IPs:"
        exec_node "$NODE2" ip addr show 2>&1 || echo "(command failed)"
        return 1
    fi
}

test_correct_master() {
    subheader "Correct MASTER Election"

    # Node1 should be MASTER (higher priority)
    local vip_owner
    vip_owner=$(get_vip_owner)

    # Get priorities
    local node1_priority node2_priority
    node1_priority=$(uci_get "$NODE1" "ha-cluster.lan.priority" 2>/dev/null || echo "100")
    node2_priority=$(uci_get "$NODE2" "ha-cluster.lan.priority" 2>/dev/null || echo "100")

    info "Node1 priority: $node1_priority"
    info "Node2 priority: $node2_priority"
    info "VIP owner: $vip_owner"

    # The node with higher priority should be MASTER
    if [ "$node1_priority" -gt "$node2_priority" ]; then
        if [ "$vip_owner" = "$NODE1" ]; then
            pass "Correct MASTER: $NODE1 (priority $node1_priority > $node2_priority)"
        else
            fail "Wrong MASTER: expected $NODE1 (priority $node1_priority), got $vip_owner"
            return 1
        fi
    elif [ "$node2_priority" -gt "$node1_priority" ]; then
        if [ "$vip_owner" = "$NODE2" ]; then
            pass "Correct MASTER: $NODE2 (priority $node2_priority > $node1_priority)"
        else
            fail "Wrong MASTER: expected $NODE2 (priority $node2_priority), got $vip_owner"
            return 1
        fi
    else
        # Equal priorities - either is acceptable
        pass "MASTER elected: $vip_owner (equal priorities)"
    fi
}

test_backup_no_vip() {
    subheader "BACKUP Has No VIP"

    # Wait for VRRP to stabilize - poll until exactly one node has VIP
    wait_for_vrrp_stable 15

    local vip_owner
    vip_owner=$(get_vip_owner)

    if [ "$vip_owner" = "$NODE1" ]; then
        # NODE2 should be BACKUP (no VIP)
        if ! has_vip "$NODE2"; then
            pass "$NODE2 (BACKUP) does not have VIP"
        else
            fail "$NODE2 (BACKUP) should not have VIP"
            return 1
        fi
    elif [ "$vip_owner" = "$NODE2" ]; then
        # NODE1 should be BACKUP (no VIP)
        if ! has_vip "$NODE1"; then
            pass "$NODE1 (BACKUP) does not have VIP"
        else
            fail "$NODE1 (BACKUP) should not have VIP"
            return 1
        fi
    fi
}

test_vrrp_states() {
    subheader "VRRP States"

    local node1_state node2_state
    node1_state=$(get_vrrp_state "$NODE1")
    node2_state=$(get_vrrp_state "$NODE2")

    info "$NODE1 state: $node1_state"
    info "$NODE2 state: $node2_state"

    # One should be MASTER, one should be BACKUP
    # States are queried via ubus (if available) or inferred from VIP ownership
    if [ "$node1_state" = "MASTER" ] && [ "$node2_state" = "BACKUP" ]; then
        pass "Correct states: $NODE1=MASTER, $NODE2=BACKUP"
    elif [ "$node1_state" = "BACKUP" ] && [ "$node2_state" = "MASTER" ]; then
        pass "Correct states: $NODE1=BACKUP, $NODE2=MASTER"
    else
        fail "Invalid states: $NODE1=$node1_state, $NODE2=$node2_state"
        return 1
    fi
}

test_only_one_master() {
    subheader "Single MASTER Check"
    check_no_split_brain
}

# ============================================
# Main
# ============================================

main() {
    header "T02: VRRP Election"
    info "Validates correct MASTER/BACKUP assignment"

    test_keepalived_running_both || return 1
    test_vip_assigned || return 1
    test_correct_master || return 1
    test_backup_no_vip || return 1
    test_vrrp_states || return 1
    test_only_one_master || return 1

    return 0
}

main
exit $?
