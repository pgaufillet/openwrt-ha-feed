#!/bin/sh
# 20-no-lease-sync.sh - Test T20: HA Cluster Without lease-sync
#
# Validates that ha-cluster starts and operates correctly when
# lease-sync binary is not installed and DHCP lease sync is disabled.
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

LEASE_SYNC_BIN="/usr/sbin/lease-sync"
LEASE_SYNC_INIT="/etc/init.d/lease-sync"
LEASE_SYNC_CONF="/tmp/ha-cluster/lease-sync.conf"

# Saved state for restoration
ORIGINAL_SYNC_LEASES=""

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Save original sync_leases value (same on both nodes)
    ORIGINAL_SYNC_LEASES=$(uci_get "$NODE1" "ha-cluster.dhcp.sync_leases" 2>/dev/null || echo "1")
    info "Original sync_leases=$ORIGINAL_SYNC_LEASES"

    # Stop ha-cluster cleanly before modifying binaries
    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" 2>/dev/null || true
    done
    for node in "$NODE1" "$NODE2"; do
        wait_for_service_stopped "$node" "keepalived" 10
    done

    for node in "$NODE1" "$NODE2"; do
        # Move lease-sync binary (simulates uninstalled package)
        if file_exists_on_node "$node" "$LEASE_SYNC_BIN" 2>/dev/null; then
            exec_node "$node" mv "$LEASE_SYNC_BIN" "${LEASE_SYNC_BIN}.bak"
            if file_exists_on_node "$node" "${LEASE_SYNC_BIN}.bak" 2>/dev/null; then
                info "Moved lease-sync binary on $node"
            else
                fail "Failed to move lease-sync binary on $node"
                return 1
            fi
        else
            info "lease-sync binary not present on $node (already absent)"
        fi

        # Move lease-sync init script
        if file_exists_on_node "$node" "$LEASE_SYNC_INIT" 2>/dev/null; then
            exec_node "$node" mv "$LEASE_SYNC_INIT" "${LEASE_SYNC_INIT}.bak"
            if file_exists_on_node "$node" "${LEASE_SYNC_INIT}.bak" 2>/dev/null; then
                info "Moved lease-sync init script on $node"
            else
                fail "Failed to move lease-sync init script on $node"
                return 1
            fi
        else
            info "lease-sync init script not present on $node (already absent)"
        fi

        # Disable lease sync via UCI
        uci_set "$node" "ha-cluster.dhcp.sync_leases" "0"
        uci_commit "$node" "ha-cluster"

        # Remove stale config from previous run (generated when sync was enabled)
        exec_node "$node" rm -f "$LEASE_SYNC_CONF" 2>/dev/null || true
    done

    # Start ha-cluster with new configuration
    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" 2>/dev/null || true
    done

    # Wait for remaining services to stabilize
    for node in "$NODE1" "$NODE2"; do
        wait_for_service "$node" "keepalived" 30
    done

    pass "Setup complete: lease-sync removed and disabled on all nodes"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_keepalived_running() {
    subheader "Keepalived Running Without lease-sync"
    check_service_on_all_nodes "keepalived" 30
}

test_owsync_running() {
    subheader "Owsync Running Without lease-sync"

    for node in "$NODE1" "$NODE2"; do
        local sync_method
        sync_method=$(uci_get "$node" "ha-cluster.config.sync_method" 2>/dev/null || echo "owsync")
        if [ "$sync_method" != "owsync" ]; then
            skip "owsync not expected on $node (sync_method=$sync_method)" "by design"
            continue
        fi

        if service_running "$node" "owsync"; then
            pass "owsync running on $node"
        else
            fail "owsync not running on $node"
            return 1
        fi
    done
}

test_lease_sync_not_running() {
    subheader "lease-sync NOT Running"

    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "lease-sync"; then
            fail "lease-sync process still running on $node"
            return 1
        else
            pass "lease-sync not running on $node"
        fi
    done
}

test_no_lease_sync_conf() {
    subheader "No lease-sync Configuration Generated"

    for node in "$NODE1" "$NODE2"; do
        if file_exists_on_node "$node" "$LEASE_SYNC_CONF" 2>/dev/null; then
            fail "lease-sync.conf exists on $node (should not be generated)"
            return 1
        else
            pass "No lease-sync.conf on $node"
        fi
    done
}

test_vip_election() {
    subheader "VIP Election Works Without lease-sync"

    if wait_for_vip_anywhere 30; then
        pass "VIP assigned to $VIP_OWNER"
    else
        fail "No node acquired VIP within 30s"
        return 1
    fi

    check_no_split_brain
}

test_restart_idempotency() {
    subheader "Restart Idempotency Without lease-sync"

    # Stop and start ha-cluster again to verify the init script guards
    # work correctly on repeated invocations
    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" 2>/dev/null || true
    done
    for node in "$NODE1" "$NODE2"; do
        wait_for_service_stopped "$node" "keepalived" 10
    done

    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" 2>/dev/null || true
    done
    for node in "$NODE1" "$NODE2"; do
        wait_for_service "$node" "keepalived" 30
    done

    # Verify same state as initial start
    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "keepalived"; then
            pass "keepalived running after restart on $node"
        else
            fail "keepalived not running after restart on $node"
            return 1
        fi

        if service_running "$node" "lease-sync"; then
            fail "lease-sync running after restart on $node (should not be)"
            return 1
        else
            pass "lease-sync still absent after restart on $node"
        fi
    done
}

test_no_lease_sync_errors() {
    subheader "No lease-sync Errors in Syslog"

    for node in "$NODE1" "$NODE2"; do
        # Look for error-level ha-cluster messages about lease-sync
        local errors
        errors=$(exec_node "$node" logread 2>/dev/null | grep -i "ha-cluster" | grep -i "lease.sync" | grep -i "error\|failed\|cannot" || true)

        if [ -n "$errors" ]; then
            fail "lease-sync errors found in syslog on $node:"
            info "$errors"
            return 1
        else
            pass "No lease-sync errors in syslog on $node"
        fi
    done
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup: Restoring lease-sync"

    # Stop ha-cluster before restoring binaries
    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" 2>/dev/null || true
    done
    for node in "$NODE1" "$NODE2"; do
        wait_for_service_stopped "$node" "keepalived" 10
    done

    for node in "$NODE1" "$NODE2"; do
        # Restore lease-sync binary
        exec_node "$node" sh -c "[ -f ${LEASE_SYNC_BIN}.bak ] && mv ${LEASE_SYNC_BIN}.bak $LEASE_SYNC_BIN" 2>/dev/null || true

        # Restore lease-sync init script
        exec_node "$node" sh -c "[ -f ${LEASE_SYNC_INIT}.bak ] && mv ${LEASE_SYNC_INIT}.bak $LEASE_SYNC_INIT" 2>/dev/null || true

        # Restore UCI sync_leases setting
        if [ -n "$ORIGINAL_SYNC_LEASES" ]; then
            uci_set "$node" "ha-cluster.dhcp.sync_leases" "$ORIGINAL_SYNC_LEASES"
            uci_commit "$node" "ha-cluster"
        fi
    done

    # Restart ha-cluster with restored configuration
    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" 2>/dev/null || true
    done

    # Wait for cluster to fully recover
    wait_for_cluster_healthy 30

    # Wait for lease-sync to restore if it was originally enabled
    if [ "$ORIGINAL_SYNC_LEASES" = "1" ]; then
        for node in "$NODE1" "$NODE2"; do
            if wait_for_service "$node" "lease-sync" 15; then
                info "lease-sync restored on $node"
            else
                warn "lease-sync not running on $node after restore — subsequent tests may fail"
                # Force a full restart as recovery attempt
                exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
                wait_for_service "$node" "lease-sync" 15 || true
            fi
        done
    fi

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T20: HA Cluster Without lease-sync"
    info "Validates ha-cluster operates correctly when lease-sync is absent"

    local result=0

    setup || return 1

    test_keepalived_running || result=1
    test_owsync_running || result=1
    test_lease_sync_not_running || result=1
    test_no_lease_sync_conf || result=1
    test_vip_election || result=1
    test_restart_idempotency || result=1
    test_no_lease_sync_errors || result=1

    cleanup

    return $result
}

main
exit $?
