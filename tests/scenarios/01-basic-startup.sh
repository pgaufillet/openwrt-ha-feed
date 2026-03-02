#!/bin/sh
# 01-basic-startup.sh - Test T01: Basic Startup
#
# Validates that all services start correctly and ubus is available.
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

test_containers_running() {
    subheader "Containers Running"

    if node_running "$NODE1"; then
        pass "$NODE1 container is running"
    else
        fail "$NODE1 container is not running"
        return 1
    fi

    if node_running "$NODE2"; then
        pass "$NODE2 container is running"
    else
        fail "$NODE2 container is not running"
        return 1
    fi
}

test_ubus_available() {
    subheader "Ubus Availability"

    for node in "$NODE1" "$NODE2"; do
        if exec_node "$node" ubus list >/dev/null 2>&1; then
            pass "ubus available on $node"
        else
            fail "ubus not available on $node"
            return 1
        fi
    done
}

test_dnsmasq_running() {
    subheader "Dnsmasq Service"
    check_service_on_all_nodes "dnsmasq"
}

test_dnsmasq_ubus_methods() {
    subheader "Dnsmasq Ubus Methods"
    check_dnsmasq_ubus_methods
}

test_ha_cluster_enabled() {
    subheader "HA Cluster Configuration"

    for node in "$NODE1" "$NODE2"; do
        local enabled
        enabled=$(uci_get "$node" "ha-cluster.config.enabled")

        if [ "$enabled" = "1" ]; then
            pass "ha-cluster enabled on $node"
        else
            fail "ha-cluster not enabled on $node (enabled=$enabled)"
            return 1
        fi
    done
}

test_keepalived_running() {
    subheader "Keepalived Service"
    # Allow 30s wait since ha-cluster may still be starting services
    check_service_on_all_nodes "keepalived" 30
}

test_owsync_running() {
    subheader "Owsync Service"

    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "owsync"; then
            pass "owsync running on $node"
        else
            # Check if owsync is even supposed to be running
            local sync_method
            sync_method=$(uci_get "$node" "ha-cluster.config.sync_method" 2>/dev/null || echo "owsync")
            if [ "$sync_method" = "owsync" ]; then
                fail "owsync not running on $node (sync_method=$sync_method)"
                return 1
            else
                skip "owsync not expected (sync_method=$sync_method)" "by design"
            fi
        fi
    done
}

test_lease_sync_running() {
    subheader "Lease-sync Service"

    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "lease-sync"; then
            pass "lease-sync running on $node"
        else
            # Check if lease sync is enabled
            local sync_leases
            sync_leases=$(uci_get "$node" "ha-cluster.dhcp.sync_leases" 2>/dev/null || echo "0")
            if [ "$sync_leases" = "1" ]; then
                fail "lease-sync not running on $node (sync_leases=$sync_leases)"
                return 1
            else
                skip "lease-sync not expected (sync_leases=$sync_leases)" "disabled"
            fi
        fi
    done
}

test_owsync_rpcd_status() {
    subheader "Owsync Rpcd Status Interface"

    for node in "$NODE1" "$NODE2"; do
        # Check if owsync rpcd handler is available
        if ! exec_node "$node" test -x /usr/libexec/rpcd/owsync 2>/dev/null; then
            skip "owsync rpcd handler not installed on $node" "optional"
            continue
        fi

        # Call ubus owsync status and validate response
        local status_output
        status_output=$(exec_node "$node" ubus call owsync status 2>/dev/null)

        if [ -z "$status_output" ]; then
            fail "owsync rpcd status returned empty on $node"
            return 1
        fi

        # Validate JSON contains expected fields
        if echo "$status_output" | grep -q '"status"'; then
            pass "owsync rpcd status available on $node"
        else
            fail "owsync rpcd status missing 'status' field on $node"
            return 1
        fi

        # Validate status value is RUNNING (since owsync should be running)
        if echo "$status_output" | grep -q '"status": "RUNNING"'; then
            pass "owsync rpcd reports RUNNING on $node"
        else
            # Not fatal - status might be valid but not RUNNING
            local status_val
            status_val=$(echo "$status_output" | grep '"status"' | head -1)
            warn "owsync rpcd status: $status_val on $node"
        fi
    done
}

test_nodes_connectivity() {
    subheader "Inter-Node Connectivity"

    if exec_node "$NODE1" ping -c 1 -W 3 "$NODE2_BACKEND_IP" >/dev/null 2>&1; then
        pass "$NODE1 can reach $NODE2 backend IP"
    else
        fail "$NODE1 cannot reach $NODE2 backend IP ($NODE2_BACKEND_IP)"
        return 1
    fi

    if exec_node "$NODE2" ping -c 1 -W 3 "$NODE1_BACKEND_IP" >/dev/null 2>&1; then
        pass "$NODE2 can reach $NODE1 backend IP"
    else
        fail "$NODE2 cannot reach $NODE1 backend IP ($NODE1_BACKEND_IP)"
        return 1
    fi
}

# ============================================
# Main
# ============================================

main() {
    header "T01: Basic Startup"
    info "Validates all services start correctly and ubus is available"

    test_containers_running || return 1
    test_ubus_available || return 1
    test_dnsmasq_running || return 1
    test_dnsmasq_ubus_methods || return 1
    test_ha_cluster_enabled || return 1
    test_keepalived_running || return 1

    # Non-fatal: owsync may not run if sync_method is not 'owsync' or config sync is disabled
    run_nonfatal test_owsync_running "optional service - depends on sync_method config"

    # Non-fatal: owsync rpcd status interface (monitoring only)
    run_nonfatal test_owsync_rpcd_status "optional - rpcd handler may not be installed"

    # Non-fatal: lease-sync may not run if sync_leases is disabled in ha-cluster config
    run_nonfatal test_lease_sync_running "optional service - depends on sync_leases config"

    test_nodes_connectivity || return 1

    return 0
}

main
exit $?
