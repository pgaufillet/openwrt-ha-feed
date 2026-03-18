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

test_dnsmasq_ha_overlay() {
    subheader "Dnsmasq HA Overlay"

    for node in "$NODE1" "$NODE2"; do
        # Determine dnsmasq's actual conf-dir from the generated config
        local confdir
        confdir=$(exec_node "$node" sh -c 'grep "^conf-dir=" /var/etc/dnsmasq.conf.* 2>/dev/null | head -1 | cut -d= -f2 | cut -d, -f1')
        if [ -z "$confdir" ]; then
            confdir="/tmp/dnsmasq.d"
            warn "Could not determine dnsmasq confdir on $node, using default"
        fi
        info "dnsmasq confdir on $node: $confdir"

        # Verify overlay file exists in the correct conf-dir
        local overlay_path="$confdir/ha-cluster.conf"
        if exec_node "$node" test -f "$overlay_path" 2>/dev/null; then
            pass "HA overlay file exists on $node ($overlay_path)"
        else
            fail "HA overlay file missing on $node ($overlay_path)"
            info "Contents of $confdir:"
            exec_node "$node" ls -la "$confdir" 2>/dev/null || echo "(directory not found)"
            return 1
        fi

        # Verify overlay contains script-on-renewal
        local overlay_content
        overlay_content=$(exec_node "$node" cat "$overlay_path" 2>/dev/null)
        if echo "$overlay_content" | grep -q "script-on-renewal"; then
            pass "Overlay contains script-on-renewal on $node"
        else
            fail "Overlay missing script-on-renewal on $node"
            info "Overlay content: $overlay_content"
            return 1
        fi

        # Verify force=1 is set on VIP interfaces (required for lease-sync)
        local force_val
        force_val=$(uci_get "$node" "dhcp.lan.force" 2>/dev/null)
        if [ "$force_val" = "1" ]; then
            pass "dhcp.lan.force=1 set on $node (required for HA lease sync)"
        else
            fail "dhcp.lan.force not set on $node (ubus add_lease needs DHCP initialized)"
            return 1
        fi

        # Verify dnsmasq config actually includes conf-dir
        local dnsmasq_conf
        dnsmasq_conf=$(exec_node "$node" sh -c 'grep "^conf-dir=" /var/etc/dnsmasq.conf.* 2>/dev/null | head -1')
        if [ -n "$dnsmasq_conf" ]; then
            pass "dnsmasq config uses conf-dir on $node"
        else
            warn "Cannot confirm conf-dir in dnsmasq config on $node"
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

    test_dnsmasq_ha_overlay || return 1
    test_nodes_connectivity || return 1

    return 0
}

main
exit $?
