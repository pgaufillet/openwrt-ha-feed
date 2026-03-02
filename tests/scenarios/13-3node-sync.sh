#!/bin/sh
# 13-3node-sync.sh - Test T13: 3-Node Configuration and Lease Sync
#
# Verifies that owsync and lease-sync work correctly in a 3-node mesh.
# Each node should sync with all other nodes.
# Requires: 3-node cluster (docker-compose.yml + docker-compose.3node.yml)
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

# Load test framework
. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/assertions.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

# Test-specific constants
# Use test_sync which is in the allowed config_files list for owsync
TEST_CONFIG_FILE="/etc/config/test_sync"
TEST_VALUE_PREFIX="sync_test_value_"

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

test_sync_services_running() {
    subheader "Sync Services Running on All Nodes"

    local all_ok=true

    for node in $(get_active_nodes); do
        if service_running "$node" "owsync"; then
            pass "owsync running on $node"
        else
            fail "owsync not running on $node"
            all_ok=false
        fi

        if service_running "$node" "lease-sync"; then
            pass "lease-sync running on $node"
        else
            fail "lease-sync not running on $node"
            all_ok=false
        fi
    done

    [ "$all_ok" = "true" ]
}

test_config_sync_from_node1() {
    subheader "Config Sync: Node1 -> All Nodes"

    local test_value="${TEST_VALUE_PREFIX}node1_$(date +%s)"

    # Create test file on Node1
    info "Creating test config on $NODE1: $test_value"
    create_test_file "$NODE1" "$TEST_CONFIG_FILE" "config test_section
    option test_value '$test_value'
"

    # Trigger sync
    trigger_owsync "$NODE1"

    # Verify sync to Node2
    if wait_for_file_content "$NODE2" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE2"
    else
        fail "Config not synced to $NODE2"
        return 1
    fi

    # Verify sync to Node3
    if wait_for_file_content "$NODE3" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE3"
    else
        fail "Config not synced to $NODE3"
        return 1
    fi
}

test_config_sync_from_node2() {
    subheader "Config Sync: Node2 -> All Nodes"

    local test_value="${TEST_VALUE_PREFIX}node2_$(date +%s)"

    # Create test file on Node2
    info "Creating test config on $NODE2: $test_value"
    create_test_file "$NODE2" "$TEST_CONFIG_FILE" "config test_section
    option test_value '$test_value'
"

    # Trigger sync
    trigger_owsync "$NODE2"

    # Verify sync to Node1
    if wait_for_file_content "$NODE1" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE1"
    else
        fail "Config not synced to $NODE1"
        return 1
    fi

    # Verify sync to Node3
    if wait_for_file_content "$NODE3" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE3"
    else
        fail "Config not synced to $NODE3"
        return 1
    fi
}

test_config_sync_from_node3() {
    subheader "Config Sync: Node3 -> All Nodes"

    local test_value="${TEST_VALUE_PREFIX}node3_$(date +%s)"

    # Create test file on Node3
    info "Creating test config on $NODE3: $test_value"
    create_test_file "$NODE3" "$TEST_CONFIG_FILE" "config test_section
    option test_value '$test_value'
"

    # Trigger sync
    trigger_owsync "$NODE3"

    # Verify sync to Node1
    if wait_for_file_content "$NODE1" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE1"
    else
        fail "Config not synced to $NODE1"
        return 1
    fi

    # Verify sync to Node2
    if wait_for_file_content "$NODE2" "$TEST_CONFIG_FILE" "$test_value" "$SYNC_TIMEOUT"; then
        pass "Config synced to $NODE2"
    else
        fail "Config not synced to $NODE2"
        return 1
    fi
}

test_lease_sync_to_all() {
    subheader "Lease Sync: Add Lease -> All Nodes"

    local test_ip="192.168.50.200"
    local test_mac="aa:bb:cc:dd:ee:11"
    local test_hostname="test-3node-client"
    local expires=$(($(date +%s) + 3600))

    # Add lease on Node1 and broadcast to trigger lease-sync
    info "Adding lease on $NODE1: $test_ip"
    add_lease "$NODE1" "$test_ip" "$test_mac" "$test_hostname" "$expires"
    broadcast_lease_event "$NODE1" "add" "$test_ip" "$test_mac" "$test_hostname" "$expires"

    # Verify lease appears on Node1
    if wait_for_ubus_lease "$NODE1" "$test_ip" 10; then
        pass "Lease exists on $NODE1 (source)"
    else
        fail "Lease not found on $NODE1 (source)"
        return 1
    fi

    # Verify sync to Node2
    if wait_for_ubus_lease "$NODE2" "$test_ip" "$SYNC_TIMEOUT"; then
        pass "Lease synced to $NODE2"
    else
        fail "Lease not synced to $NODE2"
        return 1
    fi

    # Verify sync to Node3
    if wait_for_ubus_lease "$NODE3" "$test_ip" "$SYNC_TIMEOUT"; then
        pass "Lease synced to $NODE3"
    else
        fail "Lease not synced to $NODE3"
        return 1
    fi
}

test_lease_delete_sync() {
    subheader "Lease Sync: Delete Lease -> All Nodes"

    local test_ip="192.168.50.200"
    local test_mac="aa:bb:cc:dd:ee:11"

    # Delete lease on Node1 and broadcast to trigger lease-sync
    info "Deleting lease on $NODE1: $test_ip"
    delete_lease "$NODE1" "$test_ip"
    broadcast_lease_event "$NODE1" "del" "$test_ip" "$test_mac"

    # Verify removal from Node1
    if wait_for_ubus_lease_absent "$NODE1" "$test_ip" 10; then
        pass "Lease removed from $NODE1 (source)"
    else
        fail "Lease still exists on $NODE1 (source)"
        return 1
    fi

    # Verify removal from Node2
    if wait_for_ubus_lease_absent "$NODE2" "$test_ip" "$SYNC_TIMEOUT"; then
        pass "Lease removal synced to $NODE2"
    else
        fail "Lease not removed from $NODE2"
        return 1
    fi

    # Verify removal from Node3
    if wait_for_ubus_lease_absent "$NODE3" "$test_ip" "$SYNC_TIMEOUT"; then
        pass "Lease removal synced to $NODE3"
    else
        fail "Lease not removed from $NODE3"
        return 1
    fi
}

test_lease_counts_equal() {
    subheader "Lease Counts Equal on All Nodes"

    local node1_count node2_count node3_count
    node1_count=$(get_ubus_lease_count "$NODE1")
    node2_count=$(get_ubus_lease_count "$NODE2")
    node3_count=$(get_ubus_lease_count "$NODE3")

    info "$NODE1 lease count: $node1_count"
    info "$NODE2 lease count: $node2_count"
    info "$NODE3 lease count: $node3_count"

    if [ "$node1_count" -eq "$node2_count" ] && [ "$node2_count" -eq "$node3_count" ]; then
        pass "All nodes have equal lease counts ($node1_count)"
    else
        fail "Lease counts differ across nodes"
        return 1
    fi
}

cleanup_test_files() {
    subheader "Cleanup Test Files"

    for node in $(get_active_nodes); do
        exec_node "$node" rm -f "$TEST_CONFIG_FILE" 2>/dev/null || true
    done
    pass "Test files cleaned up"
}

# ============================================
# Main
# ============================================

main() {
    header "T13: 3-Node Configuration and Lease Sync"
    info "Verifies sync works correctly in 3-node mesh topology"

    check_3node_cluster

    test_sync_services_running || return 1
    test_config_sync_from_node1 || return 1
    test_config_sync_from_node2 || return 1
    test_config_sync_from_node3 || return 1
    test_lease_sync_to_all || return 1
    test_lease_delete_sync || return 1
    test_lease_counts_equal || return 1
    cleanup_test_files

    return 0
}

main
exit $?
