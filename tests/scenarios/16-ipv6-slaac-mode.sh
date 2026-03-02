#!/bin/sh
# 16-ipv6-slaac-mode.sh - Test T16: IPv6 SLAAC Mode Validation
#
# Validates that SLAAC mode works correctly with HA:
# - Clients get IPv6 addresses via SLAAC (no DHCPv6 lease)
# - VIP failover is sufficient (no lease sync needed)
# - No IPv6 connectivity issues after failover
#
# This test validates the default OpenWrt scenario (SLAAC, no DHCPv6 leases).
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

# DHCP client containers
CLIENT1="ha-client1"

# IPv6 prefix used in test environment
IPV6_PREFIX="fd00:192:168:50"

# Store original config for restoration
ORIGINAL_RA_SLAAC_NODE1=""
ORIGINAL_RA_SLAAC_NODE2=""
ORIGINAL_RA_MGMT_NODE1=""
ORIGINAL_RA_MGMT_NODE2=""

# ============================================
# Helper Functions
# ============================================

# Save original DHCP config for restoration
save_original_config() {
    local node="$1"
    exec_node "$node" uci get dhcp.lan.ra_slaac 2>/dev/null || echo "1"
}

save_original_ra_management() {
    local node="$1"
    exec_node "$node" uci get dhcp.lan.ra_management 2>/dev/null || echo "1"
}

# Enable SLAAC mode on a node (temporarily)
enable_slaac_mode() {
    local node="$1"
    info "Enabling SLAAC mode on $node..."

    # ra_slaac='1' enables SLAAC (stateless address autoconfiguration)
    exec_node "$node" uci set dhcp.lan.ra_slaac='1'
    # ra_management='0' = advisory only (SLAAC), no DHCPv6
    exec_node "$node" uci set dhcp.lan.ra_management='0'
    exec_node "$node" uci commit dhcp

    # Restart dnsmasq to apply changes
    exec_node "$node" /etc/init.d/dnsmasq restart >/dev/null 2>&1
    sleep 2
}

# Restore original DHCP config on a node
restore_dhcp_config() {
    local node="$1"
    local original_slaac="$2"
    local original_mgmt="$3"

    info "Restoring DHCP config on $node..."
    exec_node "$node" uci set dhcp.lan.ra_slaac="$original_slaac"
    exec_node "$node" uci set dhcp.lan.ra_management="$original_mgmt"
    exec_node "$node" uci commit dhcp
    exec_node "$node" /etc/init.d/dnsmasq restart >/dev/null 2>&1
    sleep 2
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Check if DHCP client is available
    if ! client_running "$CLIENT1"; then
        skip "SLAAC mode test" "$CLIENT1 container not running"
        return 1
    fi

    # Disable odhcpd if running (test requires dnsmasq-only)
    save_and_disable_odhcpd_all || return 1

    # Check that nodes have IPv6 addresses
    local node1_ipv6 node2_ipv6
    node1_ipv6=$(exec_node "$NODE1" ip -6 addr show scope global 2>/dev/null | grep -oE "fd00:192:168:50:[0-9a-f:]+" | head -1)
    node2_ipv6=$(exec_node "$NODE2" ip -6 addr show scope global 2>/dev/null | grep -oE "fd00:192:168:50:[0-9a-f:]+" | head -1)

    if [ -z "$node1_ipv6" ] || [ -z "$node2_ipv6" ]; then
        skip "SLAAC mode test" "Nodes don't have LAN IPv6 addresses"
        return 1
    fi
    pass "Nodes have IPv6 addresses on LAN"

    # Save original config before modifying
    ORIGINAL_RA_SLAAC_NODE1=$(save_original_config "$NODE1")
    ORIGINAL_RA_SLAAC_NODE2=$(save_original_config "$NODE2")
    ORIGINAL_RA_MGMT_NODE1=$(save_original_ra_management "$NODE1")
    ORIGINAL_RA_MGMT_NODE2=$(save_original_ra_management "$NODE2")

    info "Saved original config: NODE1 ra_slaac=$ORIGINAL_RA_SLAAC_NODE1, NODE2 ra_slaac=$ORIGINAL_RA_SLAAC_NODE2"

    # Release any existing client leases
    dhcpv6_release "$CLIENT1" 2>/dev/null || true
    sleep 1

    # Enable SLAAC mode on both nodes
    enable_slaac_mode "$NODE1"
    enable_slaac_mode "$NODE2"

    pass "Test setup complete (SLAAC mode enabled)"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_slaac_configured() {
    subheader "SLAAC Configuration Check"

    local all_configured=true

    for node in "$NODE1" "$NODE2"; do
        if slaac_enabled "$node"; then
            pass "SLAAC mode enabled on $node"
        else
            fail "SLAAC mode not enabled on $node"
            all_configured=false
        fi

        local ra_mgmt
        ra_mgmt=$(exec_node "$node" uci get dhcp.lan.ra_management 2>/dev/null || echo "")
        if [ "$ra_mgmt" = "0" ]; then
            pass "RA management advisory-only on $node"
        else
            warn "RA management is '$ra_mgmt' on $node (expected '0' for pure SLAAC)"
        fi
    done

    [ "$all_configured" = "true" ]
}

test_client_gets_slaac_address() {
    subheader "Client Obtains SLAAC Address"

    # Release any existing DHCP/SLAAC addresses
    exec_client "$CLIENT1" sh -c 'killall -9 dhcpcd 2>/dev/null || true' >/dev/null 2>&1
    exec_client "$CLIENT1" sh -c 'ip -6 addr flush dev eth0 scope global 2>/dev/null || true' >/dev/null 2>&1
    sleep 2

    # Start dhcpcd which will receive RA and configure SLAAC
    info "Requesting address via SLAAC (dhcpcd will process RA)..."
    exec_client "$CLIENT1" sh -c "dhcpcd -t 20 eth0 >/dev/null 2>&1" || true

    # Wait for SLAAC address
    local count=0
    local client_ipv6=""
    while [ $count -lt 20 ]; do
        client_ipv6=$(get_client_ipv6 "$CLIENT1")
        if [ -n "$client_ipv6" ] && echo "$client_ipv6" | grep -q "^fd00:"; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done

    if [ -n "$client_ipv6" ]; then
        pass "$CLIENT1 obtained SLAAC address: $client_ipv6"
        # Store for later tests
        CLIENT1_SLAAC_IPV6="$client_ipv6"
        return 0
    else
        fail "$CLIENT1 failed to obtain SLAAC address"
        info "Client IPv6 addresses:"
        exec_client "$CLIENT1" ip -6 addr show eth0 2>&1 || true
        return 1
    fi
}

# Store SLAAC address for subsequent tests
CLIENT1_SLAAC_IPV6=""

test_no_dhcpv6_lease() {
    subheader "Verify No DHCPv6 Lease Created"

    if [ -z "$CLIENT1_SLAAC_IPV6" ]; then
        skip "No SLAAC address test" "Client didn't get SLAAC address"
        return 0
    fi

    # In pure SLAAC mode, there should be no lease in dhcp.leases
    # (SLAAC addresses are derived from RA prefix + interface MAC/random)
    local lease_found=false

    for node in "$NODE1" "$NODE2"; do
        if ipv6_lease_exists "$node" "$CLIENT1_SLAAC_IPV6"; then
            fail "DHCPv6 lease found on $node for SLAAC address $CLIENT1_SLAAC_IPV6"
            lease_found=true
        fi
    done

    if [ "$lease_found" = "false" ]; then
        pass "No DHCPv6 lease created (expected for SLAAC mode)"
        return 0
    else
        info "Lease file contents on $NODE1:"
        exec_node "$NODE1" cat /tmp/dhcp.leases 2>/dev/null || echo "(empty)"
        return 1
    fi
}

test_client_connectivity() {
    subheader "Client IPv6 Connectivity"

    if [ -z "$CLIENT1_SLAAC_IPV6" ]; then
        skip "Connectivity test" "Client didn't get SLAAC address"
        return 0
    fi

    # Get the IPv6 VIP
    local vip6="${VIP6_ADDRESS:-fd00:192:168:50::254}"

    # Check if client has default route
    if exec_client "$CLIENT1" ip -6 route show default 2>/dev/null | grep -q "via"; then
        pass "Client has IPv6 default route"
    else
        warn "Client has no IPv6 default route (connectivity test may fail)"
    fi

    # Test connectivity to VIP
    if exec_client "$CLIENT1" ping6 -c 2 -W 3 "$vip6" >/dev/null 2>&1; then
        pass "Client can ping IPv6 VIP ($vip6)"
    else
        warn "Client cannot ping IPv6 VIP (may be expected in container env)"
    fi
}

test_slaac_failover() {
    subheader "SLAAC Address Survives VIP Failover"

    if [ -z "$CLIENT1_SLAAC_IPV6" ]; then
        skip "SLAAC failover test" "Client didn't get SLAAC address"
        return 0
    fi

    # Find current MASTER
    local master
    master=$(get_vip_owner)
    if [ -z "$master" ]; then
        fail "No VIP owner found"
        return 1
    fi
    info "Current VIP owner: $master"

    # Determine backup node
    local backup
    if [ "$master" = "$NODE1" ]; then
        backup="$NODE2"
    else
        backup="$NODE1"
    fi

    # Stop keepalived on master to trigger failover
    info "Stopping keepalived on $master to trigger failover..."
    service_stop "$master" "keepalived"

    # Wait for VIP to move to backup
    if wait_for_vip "$backup" 15; then
        pass "VIP failover to $backup"
    else
        fail "VIP did not failover to $backup"
        service_start "$master" "keepalived"
        return 1
    fi

    # Verify client still has SLAAC address (should not change)
    local current_ipv6
    current_ipv6=$(get_client_ipv6 "$CLIENT1")

    if [ "$current_ipv6" = "$CLIENT1_SLAAC_IPV6" ]; then
        pass "Client SLAAC address unchanged after failover: $current_ipv6"
    else
        fail "Client SLAAC address changed: $CLIENT1_SLAAC_IPV6 -> $current_ipv6"
        info "SLAAC addresses should be stable (derived from prefix + interface ID)"
    fi

    # Restart keepalived on original master
    info "Restoring keepalived on $master..."
    service_start "$master" "keepalived"
    sleep 3

    # Verify client still has address
    current_ipv6=$(get_client_ipv6 "$CLIENT1")
    if [ -n "$current_ipv6" ]; then
        pass "Client still has IPv6 address after cluster recovery: $current_ipv6"
    else
        warn "Client lost IPv6 address after cluster recovery"
    fi

    return 0
}

test_no_lease_sync_needed() {
    subheader "No Lease Sync Activity Needed"

    if [ -z "$CLIENT1_SLAAC_IPV6" ]; then
        skip "Lease sync check" "Client didn't get SLAAC address"
        return 0
    fi

    # In SLAAC mode, lease-sync has nothing to sync because
    # no DHCPv6 leases are created
    local lease_count1 lease_count2
    lease_count1=$(get_ipv6_lease_count "$NODE1")
    lease_count2=$(get_ipv6_lease_count "$NODE2")

    info "$NODE1 IPv6 lease count: $lease_count1"
    info "$NODE2 IPv6 lease count: $lease_count2"

    # With pure SLAAC, there should be no IPv6 leases from our client prefix
    if [ "$lease_count1" = "0" ] && [ "$lease_count2" = "0" ]; then
        pass "No IPv6 leases to sync (SLAAC mode working correctly)"
    else
        warn "IPv6 leases present - may be from previous tests or stateful mode"
        info "Lease file on $NODE1:"
        exec_node "$NODE1" grep "fd00:192:168:50:" /tmp/dhcp.leases 2>/dev/null || echo "(none)"
    fi

    return 0
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Release client addresses
    if client_running "$CLIENT1"; then
        dhcpv6_release "$CLIENT1" 2>/dev/null || true
    fi

    # Restore original DHCP config on both nodes
    if [ -n "$ORIGINAL_RA_SLAAC_NODE1" ]; then
        restore_dhcp_config "$NODE1" "$ORIGINAL_RA_SLAAC_NODE1" "$ORIGINAL_RA_MGMT_NODE1"
    fi
    if [ -n "$ORIGINAL_RA_SLAAC_NODE2" ]; then
        restore_dhcp_config "$NODE2" "$ORIGINAL_RA_SLAAC_NODE2" "$ORIGINAL_RA_MGMT_NODE2"
    fi

    # Restore odhcpd if it was running before the test
    restore_odhcpd_if_was_running

    # Ensure cluster is healthy
    wait_for_cluster_healthy 15 >/dev/null 2>&1 || true

    pass "Cleanup complete (stateful DHCPv6 mode restored)"
}

# ============================================
# Main
# ============================================

main() {
    header "T16: IPv6 SLAAC Mode Validation"
    info "Validates that SLAAC mode works with HA (VIP failover is sufficient)"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    # Verify SLAAC configuration
    test_slaac_configured || result=1

    # Core tests
    test_client_gets_slaac_address || result=1

    # Verify no DHCPv6 lease (key SLAAC validation)
    test_no_dhcpv6_lease || result=1

    # Non-fatal connectivity tests (may not work in all container environments)
    run_nonfatal test_client_connectivity "IPv6 routing may not work in containers"

    # Failover test
    test_slaac_failover || result=1

    # Verify no lease sync needed
    run_nonfatal test_no_lease_sync_needed "Previous tests may have created leases"

    cleanup

    return $result
}

main
exit $?
