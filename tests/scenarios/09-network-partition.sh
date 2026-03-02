#!/bin/sh
# 09-network-partition.sh - Test T09: Network Partition Recovery
#
# Validates cluster reconverges correctly after a network partition (split-brain)
# scenario. During partition, both nodes may become MASTER. After healing,
# exactly one node should be MASTER.
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
        skip "Cluster not healthy" "cannot test network partition"
        return 1
    fi

    # Check if nft or iptables is available for network partition simulation
    # nft is preferred (native fw4 on OpenWrt 24.10+), iptables as fallback
    # Note: 'command -v' is a shell built-in, must run via sh -c
    if exec_node "$NODE1" sh -c 'command -v nft' >/dev/null 2>&1; then
        info "Using nft for network partition (native fw4)"
    elif exec_node "$NODE1" sh -c 'command -v iptables' >/dev/null 2>&1; then
        info "Using iptables for network partition (legacy fallback)"
    else
        skip "Network partition test" "neither nft nor iptables available"
        return 1
    fi

    # Clean up any existing partition rules
    heal_all_partitions

    pass "Test setup complete - cluster is healthy"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_initial_single_master() {
    subheader "Verify Initial State: Single MASTER"

    # Verify exactly one node has VIP
    if check_no_split_brain; then
        local owner
        owner=$(get_vip_owner)
        info "Initial VIP owner: $owner"
    else
        fail "Cluster not in valid state before partition test"
        return 1
    fi
}

test_create_partition() {
    subheader "Create Network Partition"

    # Block traffic between nodes using iptables
    info "Blocking traffic between $NODE1 and $NODE2..."

    # NODE1 blocks NODE2
    create_network_partition "$NODE1" "$NODE2_BACKEND_IP"

    # NODE2 blocks NODE1
    create_network_partition "$NODE2" "$NODE1_BACKEND_IP"

    # Verify partition is in effect
    sleep 2
    if ! nodes_can_communicate; then
        pass "Network partition created - nodes cannot communicate"
    else
        fail "Network partition failed - nodes can still communicate"
        heal_all_partitions
        return 1
    fi
}

test_wait_for_split_brain() {
    subheader "Wait for Split-Brain (Both Nodes Become MASTER)"

    # During a network partition, VRRP will detect peer as down
    # Each node will promote itself to MASTER
    # This takes VRRP advertisement interval + dead interval (typically 3-4s)

    info "Waiting for VRRP failover on both nodes..."
    local split_brain_detected=false
    local count=0
    local max_wait=20  # VRRP should elect within this time

    while [ $count -lt $max_wait ]; do
        local node1_has_vip node2_has_vip
        node1_has_vip=$(has_vip "$NODE1" && echo "yes" || echo "no")
        node2_has_vip=$(has_vip "$NODE2" && echo "yes" || echo "no")

        if [ "$node1_has_vip" = "yes" ] && [ "$node2_has_vip" = "yes" ]; then
            split_brain_detected=true
            break
        fi

        sleep 1
        count=$((count + 1))
    done

    if [ "$split_brain_detected" = "true" ]; then
        pass "Split-brain detected: both nodes have VIP"
        info "This is expected during network partition"
    else
        info "Split-brain not detected (may depend on VRRP timing)"
        info "NODE1 has VIP: $(has_vip "$NODE1" && echo yes || echo no)"
        info "NODE2 has VIP: $(has_vip "$NODE2" && echo yes || echo no)"
        # This isn't necessarily a failure - some VRRP configs may not split-brain quickly
    fi
}

test_heal_partition() {
    subheader "Heal Network Partition"

    info "Restoring network connectivity..."

    # Remove iptables rules
    heal_all_partitions

    # Verify connectivity restored
    sleep 2
    local count=0
    while [ $count -lt 10 ]; do
        if nodes_can_communicate; then
            pass "Network partition healed - nodes can communicate"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    fail "Network partition healing failed - nodes still cannot communicate"
    return 1
}

test_wait_for_election() {
    subheader "Wait for VRRP Election"

    # After partition heals, VRRP should reconverge
    # The node with higher priority (or lower IP if equal) becomes MASTER
    # The other becomes BACKUP

    info "Waiting for VRRP to elect single MASTER..."

    if wait_for_vrrp_stable 20; then
        local elected
        elected=$(get_vip_owner)
        info "VRRP election complete: $elected is MASTER"
        pass "VRRP election completed"
    else
        fail "VRRP election did not complete within 20s"
        info "NODE1 has VIP: $(has_vip "$NODE1" && echo yes || echo no)"
        info "NODE2 has VIP: $(has_vip "$NODE2" && echo yes || echo no)"
        return 1
    fi
}

test_verify_single_master() {
    subheader "Verify Single MASTER After Recovery"

    # Use the check_no_split_brain helper
    if check_no_split_brain; then
        local owner
        owner=$(get_vip_owner)
        pass "Single MASTER confirmed: $owner"
    else
        fail "Split-brain persists after partition healed"
        return 1
    fi
}

test_verify_backup_state() {
    subheader "Verify BACKUP Node State"

    local master backup
    master=$(get_vip_owner)

    if [ "$master" = "$NODE1" ]; then
        backup="$NODE2"
    else
        backup="$NODE1"
    fi

    # Verify backup doesn't have VIP
    if ! has_vip "$backup"; then
        pass "$backup is BACKUP (no VIP)"
    else
        fail "$backup has VIP but should be BACKUP"
        return 1
    fi

    # Verify keepalived is running on backup
    if service_running "$backup" "keepalived"; then
        pass "keepalived running on BACKUP node"
    else
        fail "keepalived not running on BACKUP node"
        return 1
    fi
}

test_cluster_services_healthy() {
    subheader "Verify All Cluster Services Healthy"

    local all_ok=true

    for node in "$NODE1" "$NODE2"; do
        for service in keepalived; do
            if service_running "$node" "$service"; then
                pass "$service running on $node"
            else
                fail "$service not running on $node"
                all_ok=false
            fi
        done
    done

    # Check optional services
    for node in "$NODE1" "$NODE2"; do
        for service in owsync lease-sync; do
            if service_running "$node" "$service"; then
                pass "$service running on $node"
            else
                info "$service not running on $node (may be optional)"
            fi
        done
    done

    [ "$all_ok" = "true" ]
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Ensure all partition rules are removed
    heal_all_partitions

    # Verify cluster is healthy
    if wait_for_cluster_healthy 15; then
        pass "Cluster healthy after cleanup"
    else
        info "Cluster may need manual intervention"
    fi

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T09: Network Partition Recovery"
    info "Validates cluster reconverges after split-brain"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    test_initial_single_master || result=1
    test_create_partition || { cleanup; return 1; }  # Must cleanup on failure
    test_wait_for_split_brain  # Non-fatal - split-brain may not happen quickly
    test_heal_partition || { cleanup; return 1; }
    test_wait_for_election || result=1
    test_verify_single_master || result=1
    test_verify_backup_state || result=1
    test_cluster_services_healthy || result=1

    cleanup

    return $result
}

main
exit $?
