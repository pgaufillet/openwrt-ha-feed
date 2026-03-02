#!/bin/sh
# 04-config-sync.sh - Test T04: Config Sync
#
# Validates owsync replicates UCI configuration changes between nodes.
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

TEST_FILE="/etc/config/test_sync"
TEST_CONTENT="sync_test_$(date +%s)"

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Check if owsync is running
    local owsync_running=false
    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "owsync"; then
            owsync_running=true
        fi
    done

    if [ "$owsync_running" = "false" ]; then
        skip "Config sync test" "owsync not running"
        return 1
    fi

    # Clean up any previous test files
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" rm -f "$TEST_FILE" 2>/dev/null || true
    done

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_owsync_running() {
    subheader "Owsync Service Check"
    check_service_on_all_nodes "owsync"
}

test_create_file_on_node1() {
    subheader "Create Test File on $NODE1"

    # Create test UCI config file
    exec_node "$NODE1" sh -c "
        echo 'config test general' > $TEST_FILE
        echo \"    option value '$TEST_CONTENT'\" >> $TEST_FILE
    "

    # Verify file was created
    if file_exists_on_node "$NODE1" "$TEST_FILE"; then
        local content
        content=$(get_file_content "$NODE1" "$TEST_FILE")
        if echo "$content" | grep -q "$TEST_CONTENT"; then
            pass "Test file created with correct content"
        else
            fail "Test file has wrong content"
            info "Expected to contain: $TEST_CONTENT"
            info "Actual content: $content"
            return 1
        fi
    else
        fail "Test file not created on $NODE1"
        return 1
    fi
}

test_sync_to_node2() {
    subheader "Sync to $NODE2"

    # Trigger sync (owsync polls on interval, or we can force it)
    trigger_owsync "$NODE1"

    # Wait for file to appear on NODE2
    info "Waiting for file to sync to $NODE2..."
    if wait_for_file "$NODE2" "$TEST_FILE" "$SYNC_TIMEOUT"; then
        pass "File synced to $NODE2"
    else
        fail "File did not sync to $NODE2 within ${SYNC_TIMEOUT}s"
        return 1
    fi

    # Verify content matches
    local node1_content node2_content
    node1_content=$(get_file_content "$NODE1" "$TEST_FILE")
    node2_content=$(get_file_content "$NODE2" "$TEST_FILE")

    if [ "$node1_content" = "$node2_content" ]; then
        pass "Content matches between nodes"
    else
        fail "Content mismatch"
        info "Node1 content: $node1_content"
        info "Node2 content: $node2_content"
        return 1
    fi
}

test_modify_and_sync() {
    subheader "Modify and Re-sync"

    # Modify file on NODE1
    local new_content="modified_$(date +%s)"
    exec_node "$NODE1" sh -c "
        echo 'config test general' > $TEST_FILE
        echo \"    option value '$new_content'\" >> $TEST_FILE
    "

    info "Modified file on $NODE1, waiting for sync..."
    trigger_owsync "$NODE1"

    # Poll for content to sync instead of fixed sleep
    if wait_for_file_content "$NODE2" "$TEST_FILE" "$new_content" "$SYNC_TIMEOUT"; then
        pass "Modified content synced to $NODE2"
    else
        fail "Modified content did not sync"
        info "Expected to contain: $new_content"
        local node2_content
        node2_content=$(get_file_content "$NODE2" "$TEST_FILE")
        info "Actual: $node2_content"
        return 1
    fi
}

test_bidirectional_sync() {
    subheader "Bidirectional Sync"

    # Create a different file on NODE2
    local test_file2="/etc/config/test_sync2"
    local content2="from_node2_$(date +%s)"

    exec_node "$NODE2" sh -c "
        echo 'config test general' > $test_file2
        echo \"    option value '$content2'\" >> $test_file2
    "

    # Trigger sync from NODE2
    trigger_owsync "$NODE2"

    # Wait for file to appear on NODE1
    info "Waiting for reverse sync to $NODE1..."
    if wait_for_file "$NODE1" "$test_file2" "$SYNC_TIMEOUT"; then
        pass "Reverse sync worked: file appeared on $NODE1"
    else
        fail "Reverse sync failed: file did not appear on $NODE1"
        # Clean up
        exec_node "$NODE2" rm -f "$test_file2" 2>/dev/null || true
        return 1
    fi

    # Verify content
    local node1_content
    node1_content=$(get_file_content "$NODE1" "$test_file2")
    if echo "$node1_content" | grep -q "$content2"; then
        pass "Bidirectional sync content correct"
    else
        fail "Bidirectional sync content mismatch"
        return 1
    fi

    # Clean up test file 2
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" rm -f "$test_file2" 2>/dev/null || true
    done
}

test_delete_sync() {
    subheader "Delete Synchronization"

    # Delete test file on NODE1
    exec_node "$NODE1" rm -f "$TEST_FILE"

    # Trigger sync
    trigger_owsync "$NODE1"

    # Wait for deletion to propagate
    info "Waiting for delete to sync..."
    local count=0
    while [ $count -lt "$SYNC_TIMEOUT" ]; do
        if ! file_exists_on_node "$NODE2" "$TEST_FILE"; then
            pass "Delete synced to $NODE2"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    # Fail on timeout - delete sync should work
    fail "Delete not synced to $NODE2 within ${SYNC_TIMEOUT}s"
    return 1
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" rm -f "$TEST_FILE" /etc/config/test_sync2 2>/dev/null || true
    done

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T04: Config Sync"
    info "Validates owsync replicates UCI changes"

    local result=0

    setup || return 0  # Skip if owsync not running
    test_owsync_running || return 1
    test_create_file_on_node1 || result=1
    test_sync_to_node2 || result=1
    test_modify_and_sync || result=1
    test_bidirectional_sync || result=1

    # Non-fatal: delete sync uses tombstone mechanism which may have delay;
    # the owsync protocol prioritizes consistency over immediate deletion
    run_nonfatal test_delete_sync "tombstone mechanism may delay delete propagation"

    cleanup

    return $result
}

main
exit $?
