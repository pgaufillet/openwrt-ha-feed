#!/bin/sh
# 21-config-generation.sh - Test T21: Configuration Generation
#
# Validates keepalived.conf generation correctness and stale config
# cleanup when services are disabled.
#
# Tests:
#   - VRRP instance names match UCI section names (no VI_ prefix)
#   - Unicast auto-derivation from peer config when vrrp_transport=unicast
#   - sync_enabled=0 peers excluded from owsync/lease-sync but included in unicast
#   - Instance lifecycle: new instance with VIP appears, empty instance skipped
#   - Multiple instances on same interface both generated
#   - Per-instance unicast override takes precedence over auto-derivation
#   - owsync.conf is removed when sync_method != owsync
#   - lease-sync.conf is removed when lease sync is disabled
#
# Note: IPv6 instance naming (${section}_v6) is not tested here
# because IPv6 VIPs are not configured in the default test environment.
# See T14 (ipv6-vip) for IPv6-specific tests.
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

KEEPALIVED_CONF="/tmp/ha-cluster/keepalived.conf"
OWSYNC_CONF="/tmp/ha-cluster/owsync.conf"
LEASE_SYNC_CONF="/tmp/ha-cluster/lease-sync.conf"

# Saved state for restoration
ORIGINAL_SYNC_METHOD=""
ORIGINAL_SYNC_LEASES=""

# ============================================
# Test Cases - Instance Naming
# ============================================

test_instance_name_no_vi_prefix() {
    subheader "VRRP Instance Name Has No VI_ Prefix"

    for node in "$NODE1" "$NODE2"; do
        local conf
        conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

        if [ -z "$conf" ]; then
            fail "keepalived.conf not found on $node"
            return 1
        fi

        # Verify the 'main' vrrp_instance section exists in UCI
        local vrid
        vrid=$(uci_get "$node" "ha-cluster.main.vrid" 2>/dev/null)
        if [ -z "$vrid" ]; then
            fail "No vrrp_instance 'main' section in UCI on $node"
            return 1
        fi

        # Check that keepalived uses section name directly, not VI_<name>
        if echo "$conf" | grep -q "vrrp_instance main {"; then
            pass "Instance name is 'main' on $node (no prefix)"
        else
            fail "Instance name mismatch on $node"
            info "Expected: vrrp_instance main {"
            info "Got: $(echo "$conf" | grep 'vrrp_instance ')"
            return 1
        fi

        # Ensure no VI_ prefix anywhere
        if echo "$conf" | grep -q "vrrp_instance VI_"; then
            fail "Found VI_ prefix in instance name on $node"
            info "$(echo "$conf" | grep 'vrrp_instance VI_')"
            return 1
        else
            pass "No VI_ prefix in any instance name on $node"
        fi
    done
}

test_notify_scripts_match_instance_name() {
    subheader "Notify Scripts Use Correct Instance Name"

    for node in "$NODE1" "$NODE2"; do
        local conf
        conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

        if [ -z "$conf" ]; then
            fail "keepalived.conf not found on $node"
            return 1
        fi

        # Notify scripts should reference NAME=main (not NAME=VI_main)
        if echo "$conf" | grep -q "NAME=main /sbin/hotplug-call"; then
            pass "Notify scripts use NAME=main on $node"
        else
            fail "Notify scripts have wrong instance name on $node"
            info "$(echo "$conf" | grep 'NAME=')"
            return 1
        fi

        if echo "$conf" | grep -q "NAME=VI_"; then
            fail "Notify scripts have VI_ prefix on $node"
            return 1
        else
            pass "No VI_ prefix in notify scripts on $node"
        fi
    done
}

# ============================================
# Test Cases - Unicast Auto-Derivation
# ============================================

test_unicast_auto_derivation() {
    subheader "Unicast Auto-Derived From Peer Config"

    local node="$NODE1"

    # Get the peer address for NODE1 (should be NODE2's IP)
    local peer_addr
    peer_addr=$(uci_get "$node" "ha-cluster.peer1.address")
    if [ -z "$peer_addr" ]; then
        fail "No peer1 address configured on $node"
        return 1
    fi
    info "Peer address: $peer_addr"

    # Set vrrp_transport=unicast and add source_address
    uci_set "$node" "ha-cluster.config.vrrp_transport" "unicast"
    uci_set "$node" "ha-cluster.peer1.source_address" "10.99.0.1"
    uci_commit "$node" "ha-cluster"

    # Restart to regenerate config
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    # Verify unicast_src_ip auto-derived from peer source_address
    if echo "$conf" | grep -q "unicast_src_ip 10.99.0.1"; then
        pass "unicast_src_ip auto-derived from peer source_address"
    else
        fail "unicast_src_ip not found or wrong value"
        info "Expected: unicast_src_ip 10.99.0.1"
        info "Config unicast lines: $(echo "$conf" | grep -i unicast)"
        return 1
    fi

    # Verify unicast_peer auto-derived from peer address
    if echo "$conf" | grep -q "$peer_addr"; then
        pass "unicast_peer contains peer address ($peer_addr)"
    else
        fail "unicast_peer does not contain peer address"
        info "Expected peer: $peer_addr"
        info "Config: $(echo "$conf" | grep -A5 'unicast_peer')"
        return 1
    fi

    # Restore
    uci_set "$node" "ha-cluster.config.vrrp_transport" "multicast"
    exec_node "$node" uci delete ha-cluster.peer1.source_address 2>/dev/null || true
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

test_multicast_no_unicast_block() {
    subheader "Multicast Mode Has No Unicast Block"

    local node="$NODE1"

    # Ensure multicast (default)
    uci_set "$node" "ha-cluster.config.vrrp_transport" "multicast"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    if echo "$conf" | grep -q "unicast_peer"; then
        fail "unicast_peer block found in multicast mode"
        return 1
    else
        pass "No unicast block in multicast mode"
    fi
}

# ============================================
# Test Cases - sync_enabled Filtering
# ============================================

test_sync_enabled_filtering() {
    subheader "sync_enabled=0 Peer Excluded From Sync Configs"

    local node="$NODE1"

    # Disable sync for peer1
    uci_set "$node" "ha-cluster.peer1.sync_enabled" "0"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local peer_addr
    peer_addr=$(uci_get "$node" "ha-cluster.peer1.address")

    # Check owsync.conf: peer should NOT be present
    local owsync_conf
    owsync_conf=$(get_file_content "$node" "$OWSYNC_CONF")
    if [ -n "$owsync_conf" ] && echo "$owsync_conf" | grep -qF "peer=$peer_addr"; then
        fail "sync_enabled=0 peer still in owsync.conf"
        return 1
    else
        pass "sync_enabled=0 peer excluded from owsync.conf"
    fi

    # Check lease-sync.conf: peer should NOT be present
    local ls_conf
    ls_conf=$(get_file_content "$node" "$LEASE_SYNC_CONF")
    if [ -n "$ls_conf" ] && echo "$ls_conf" | grep -qF "peer=$peer_addr"; then
        fail "sync_enabled=0 peer still in lease-sync.conf"
        return 1
    else
        pass "sync_enabled=0 peer excluded from lease-sync.conf"
    fi

    # Restore
    exec_node "$node" uci delete ha-cluster.peer1.sync_enabled 2>/dev/null || true
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

test_sync_enabled_unicast_included() {
    subheader "sync_enabled=0 Peer Still In Unicast Peers"

    local node="$NODE1"
    local peer_addr
    peer_addr=$(uci_get "$node" "ha-cluster.peer1.address")

    # Set unicast + disable sync for peer1
    uci_set "$node" "ha-cluster.config.vrrp_transport" "unicast"
    uci_set "$node" "ha-cluster.peer1.sync_enabled" "0"
    uci_set "$node" "ha-cluster.peer1.source_address" "10.99.0.1"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    # Peer should still appear in unicast_peer block
    if echo "$conf" | grep -q "$peer_addr"; then
        pass "sync_enabled=0 peer still in unicast_peer (VRRP participation)"
    else
        fail "sync_enabled=0 peer missing from unicast_peer"
        info "Expected: $peer_addr in unicast_peer block"
        info "Config: $(echo "$conf" | grep -A5 'unicast_peer')"
        return 1
    fi

    # Restore
    uci_set "$node" "ha-cluster.config.vrrp_transport" "multicast"
    exec_node "$node" uci delete ha-cluster.peer1.sync_enabled 2>/dev/null || true
    exec_node "$node" uci delete ha-cluster.peer1.source_address 2>/dev/null || true
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

# ============================================
# Test Cases - Instance Lifecycle
# ============================================

test_new_instance_appears_in_config() {
    subheader "New Instance With VIP Appears In keepalived.conf"

    local node="$NODE1"

    # Create a second instance
    uci_set "$node" "ha-cluster.guest_1" "vrrp_instance"
    uci_set "$node" "ha-cluster.guest_1.vrid" "72"
    uci_set "$node" "ha-cluster.guest_1.interface" "lan"
    uci_set "$node" "ha-cluster.guest_1.priority" "100"
    uci_set "$node" "ha-cluster.guest_1.nopreempt" "1"

    # Add a VIP referencing this instance
    uci_set "$node" "ha-cluster.vip_guest" "vip"
    uci_set "$node" "ha-cluster.vip_guest.enabled" "1"
    uci_set "$node" "ha-cluster.vip_guest.vrrp_instance" "guest_1"
    uci_set "$node" "ha-cluster.vip_guest.interface" "lan"
    uci_set "$node" "ha-cluster.vip_guest.address" "192.168.50.200"
    uci_set "$node" "ha-cluster.vip_guest.netmask" "255.255.255.0"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    if echo "$conf" | grep -q "vrrp_instance guest_1 {"; then
        pass "New instance guest_1 appears in keepalived.conf"
    else
        fail "Instance guest_1 not found in keepalived.conf"
        info "Instances found: $(echo "$conf" | grep 'vrrp_instance ')"
        # Cleanup before returning
        exec_node "$node" uci delete ha-cluster.vip_guest 2>/dev/null || true
        exec_node "$node" uci delete ha-cluster.guest_1 2>/dev/null || true
        uci_commit "$node" "ha-cluster"
        stop_ha_cluster "$node" 2>/dev/null || true
        wait_for_service_stopped "$node" "keepalived" 10
        start_ha_cluster "$node" 2>/dev/null || true
        wait_for_service "$node" "keepalived" 30
        return 1
    fi

    if echo "$conf" | grep -q "virtual_router_id 72"; then
        pass "Instance guest_1 has VRID 72"
    else
        fail "VRID 72 not found in keepalived.conf"
    fi

    # Cleanup
    exec_node "$node" uci delete ha-cluster.vip_guest
    exec_node "$node" uci delete ha-cluster.guest_1
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

test_instance_without_vips_skipped() {
    subheader "Instance With No VIPs Skipped In keepalived.conf"

    local node="$NODE1"

    # Create instance with no VIPs
    uci_set "$node" "ha-cluster.empty_1" "vrrp_instance"
    uci_set "$node" "ha-cluster.empty_1.vrid" "99"
    uci_set "$node" "ha-cluster.empty_1.interface" "lan"
    uci_set "$node" "ha-cluster.empty_1.priority" "100"
    uci_set "$node" "ha-cluster.empty_1.nopreempt" "1"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    if echo "$conf" | grep -q "vrrp_instance empty_1 {"; then
        fail "Empty instance should not appear in keepalived.conf"
        exec_node "$node" uci delete ha-cluster.empty_1 2>/dev/null || true
        uci_commit "$node" "ha-cluster"
        stop_ha_cluster "$node" 2>/dev/null || true
        wait_for_service_stopped "$node" "keepalived" 10
        start_ha_cluster "$node" 2>/dev/null || true
        wait_for_service "$node" "keepalived" 30
        return 1
    else
        pass "Instance with no VIPs is skipped"
    fi

    # Original 'main' instance should still be present
    if echo "$conf" | grep -q "vrrp_instance main {"; then
        pass "Original instance 'main' still present"
    else
        fail "Original instance 'main' missing"
    fi

    # Cleanup
    exec_node "$node" uci delete ha-cluster.empty_1
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

test_multiple_instances_same_interface() {
    subheader "Multiple Instances On Same Interface Both Generated"

    local node="$NODE1"

    # Add second instance on lan (same interface as 'main')
    uci_set "$node" "ha-cluster.lan_2" "vrrp_instance"
    uci_set "$node" "ha-cluster.lan_2.vrid" "52"
    uci_set "$node" "ha-cluster.lan_2.interface" "lan"
    uci_set "$node" "ha-cluster.lan_2.priority" "150"
    uci_set "$node" "ha-cluster.lan_2.nopreempt" "1"

    # Add VIP for the second instance
    uci_set "$node" "ha-cluster.vip_lan2" "vip"
    uci_set "$node" "ha-cluster.vip_lan2.enabled" "1"
    uci_set "$node" "ha-cluster.vip_lan2.vrrp_instance" "lan_2"
    uci_set "$node" "ha-cluster.vip_lan2.interface" "lan"
    uci_set "$node" "ha-cluster.vip_lan2.address" "192.168.50.200"
    uci_set "$node" "ha-cluster.vip_lan2.netmask" "255.255.255.0"
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    # Both instances should exist
    if echo "$conf" | grep -q "vrrp_instance main {"; then
        pass "Original instance 'main' present"
    else
        fail "Instance 'main' missing"
    fi

    if echo "$conf" | grep -q "vrrp_instance lan_2 {"; then
        pass "Second instance 'lan_2' present"
    else
        fail "Instance 'lan_2' not found"
        info "Instances: $(echo "$conf" | grep 'vrrp_instance ')"
    fi

    # Verify different VRIDs
    if echo "$conf" | grep -q "virtual_router_id 52"; then
        pass "lan_2 has VRID 52"
    else
        fail "VRID 52 not found"
    fi

    # Cleanup
    exec_node "$node" uci delete ha-cluster.vip_lan2
    exec_node "$node" uci delete ha-cluster.lan_2
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

test_per_instance_unicast_override() {
    subheader "Per-Instance Unicast Override Takes Precedence"

    local node="$NODE1"

    # Set global unicast
    uci_set "$node" "ha-cluster.config.vrrp_transport" "unicast"
    uci_set "$node" "ha-cluster.peer1.source_address" "10.99.0.1"

    # Set per-instance override on 'main'
    uci_set "$node" "ha-cluster.main.unicast_src_ip" "10.88.0.1"
    exec_node "$node" uci add_list ha-cluster.main.unicast_peer=10.88.0.2
    uci_commit "$node" "ha-cluster"

    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    local conf
    conf=$(get_file_content "$node" "$KEEPALIVED_CONF")

    # Should use explicit values, not auto-derived
    if echo "$conf" | grep -q "unicast_src_ip 10.88.0.1"; then
        pass "Per-instance unicast_src_ip override used (10.88.0.1)"
    else
        fail "Per-instance override not used"
        info "Expected: unicast_src_ip 10.88.0.1"
        info "Got: $(echo "$conf" | grep 'unicast_src_ip')"
    fi

    if echo "$conf" | grep -q "10.88.0.2"; then
        pass "Per-instance unicast_peer override used (10.88.0.2)"
    else
        fail "Per-instance unicast_peer override not used"
        info "Got: $(echo "$conf" | grep -A5 'unicast_peer')"
    fi

    # Auto-derived source (10.99.0.1) should NOT appear
    if echo "$conf" | grep -q "unicast_src_ip 10.99.0.1"; then
        fail "Auto-derived unicast_src_ip should be overridden"
    else
        pass "Auto-derived value correctly overridden"
    fi

    # Cleanup
    exec_node "$node" uci delete ha-cluster.main.unicast_src_ip 2>/dev/null || true
    exec_node "$node" uci delete ha-cluster.main.unicast_peer 2>/dev/null || true
    uci_set "$node" "ha-cluster.config.vrrp_transport" "multicast"
    exec_node "$node" uci delete ha-cluster.peer1.source_address 2>/dev/null || true
    uci_commit "$node" "ha-cluster"
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30
}

# ============================================
# Test Cases - Startup Validation
# ============================================

test_missing_force_rejected() {
    subheader "Missing force=1 Rejected At Startup"

    local node="$NODE1"

    # Remove force=1 from dhcp config
    exec_node "$node" uci delete dhcp.lan.force 2>/dev/null || true
    exec_node "$node" uci -P /dev/null commit dhcp

    # Stop ha-cluster
    stop_ha_cluster "$node" 2>/dev/null || true
    wait_for_service_stopped "$node" "keepalived" 10

    # Try to start — should fail validation
    start_ha_cluster "$node" 2>/dev/null || true
    sleep 2

    # Check that keepalived is NOT running (ha-cluster refused to start)
    if service_running "$node" "keepalived"; then
        fail "ha-cluster started despite missing force=1"
        # Restore and restart
        exec_node "$node" uci set dhcp.lan.force=1
        exec_node "$node" uci -P /dev/null commit dhcp
        stop_ha_cluster "$node" 2>/dev/null || true
        wait_for_service_stopped "$node" "keepalived" 10
        start_ha_cluster "$node" 2>/dev/null || true
        wait_for_service "$node" "keepalived" 30
        return 1
    fi
    pass "ha-cluster refused to start without force=1"

    # Verify error message in logs
    local log_output
    log_output=$(exec_node "$node" logread 2>/dev/null | tail -20)
    if echo "$log_output" | grep -q "force must be '1'"; then
        pass "Error message mentions force=1 requirement"
    else
        fail "Expected error message about force=1 not found in logs"
    fi

    # Restore force=1 and restart
    exec_node "$node" uci set dhcp.lan.force=1
    exec_node "$node" uci -P /dev/null commit dhcp
    start_ha_cluster "$node" 2>/dev/null || true
    wait_for_service "$node" "keepalived" 30

    if service_running "$node" "keepalived"; then
        pass "ha-cluster starts after restoring force=1"
    else
        fail "ha-cluster failed to start after restoring force=1"
        return 1
    fi
}

# ============================================
# Test Cases - Stale Config Cleanup
# ============================================

test_owsync_conf_removed_when_disabled() {
    subheader "owsync.conf Removed When sync_method=none"

    # Save original value
    ORIGINAL_SYNC_METHOD=$(uci_get "$NODE1" "ha-cluster.config.sync_method" 2>/dev/null || echo "owsync")

    # Ensure owsync is enabled first so we actually test the removal
    if [ "$ORIGINAL_SYNC_METHOD" != "owsync" ]; then
        info "sync_method is '$ORIGINAL_SYNC_METHOD', enabling owsync first"
        for node in "$NODE1" "$NODE2"; do
            uci_set "$node" "ha-cluster.config.sync_method" "owsync"
            uci_commit "$node" "ha-cluster"
        done

        # Restart to generate owsync.conf
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
    fi

    # Verify owsync.conf exists before disabling
    for node in "$NODE1" "$NODE2"; do
        if ! file_exists_on_node "$node" "$OWSYNC_CONF" 2>/dev/null; then
            fail "owsync.conf should exist on $node before disabling (sync_method=owsync)"
            return 1
        fi
    done
    info "Confirmed owsync.conf exists on both nodes"

    # Disable owsync
    for node in "$NODE1" "$NODE2"; do
        uci_set "$node" "ha-cluster.config.sync_method" "none"
        uci_commit "$node" "ha-cluster"
    done

    # Restart ha-cluster
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

    # Verify owsync.conf is gone
    for node in "$NODE1" "$NODE2"; do
        if file_exists_on_node "$node" "$OWSYNC_CONF" 2>/dev/null; then
            fail "Stale owsync.conf still exists on $node after disabling owsync"
            return 1
        else
            pass "owsync.conf removed on $node"
        fi
    done

    # Verify owsync is not running
    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "owsync"; then
            fail "owsync still running on $node with sync_method=none"
            return 1
        else
            pass "owsync not running on $node"
        fi
    done

    # Restore sync_method before next test so cluster is in a known state
    for node in "$NODE1" "$NODE2"; do
        uci_set "$node" "ha-cluster.config.sync_method" "$ORIGINAL_SYNC_METHOD"
        uci_commit "$node" "ha-cluster"
    done
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
    info "Restored sync_method=$ORIGINAL_SYNC_METHOD between tests"
}

test_lease_sync_conf_removed_when_disabled() {
    subheader "lease-sync.conf Removed When Lease Sync Disabled"

    # Save original value
    ORIGINAL_SYNC_LEASES=$(uci_get "$NODE1" "ha-cluster.dhcp.sync_leases" 2>/dev/null || echo "1")

    # Ensure lease sync is enabled first so we actually test the removal
    if [ "$ORIGINAL_SYNC_LEASES" != "1" ]; then
        info "sync_leases is '$ORIGINAL_SYNC_LEASES', enabling lease sync first"
        for node in "$NODE1" "$NODE2"; do
            uci_set "$node" "ha-cluster.dhcp.sync_leases" "1"
            uci_set "$node" "ha-cluster.dhcp.enabled" "1"
            uci_commit "$node" "ha-cluster"
        done

        # Restart to generate lease-sync.conf
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
    fi

    # Verify lease-sync.conf exists before disabling
    for node in "$NODE1" "$NODE2"; do
        if ! file_exists_on_node "$node" "$LEASE_SYNC_CONF" 2>/dev/null; then
            fail "lease-sync.conf should exist on $node before disabling"
            return 1
        fi
    done
    info "Confirmed lease-sync.conf exists on both nodes"

    # Disable lease sync
    for node in "$NODE1" "$NODE2"; do
        uci_set "$node" "ha-cluster.dhcp.sync_leases" "0"
        uci_commit "$node" "ha-cluster"
    done

    # Restart ha-cluster
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

    # Verify lease-sync.conf is gone
    for node in "$NODE1" "$NODE2"; do
        if file_exists_on_node "$node" "$LEASE_SYNC_CONF" 2>/dev/null; then
            fail "Stale lease-sync.conf still exists on $node after disabling lease sync"
            return 1
        else
            pass "lease-sync.conf removed on $node"
        fi
    done

    # Verify lease-sync is not running
    for node in "$NODE1" "$NODE2"; do
        if service_running "$node" "lease-sync"; then
            fail "lease-sync still running on $node with sync_leases=0"
            return 1
        else
            pass "lease-sync not running on $node"
        fi
    done
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup: Restoring Configuration"

    # Stop ha-cluster before restoring config
    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" 2>/dev/null || true
    done
    for node in "$NODE1" "$NODE2"; do
        wait_for_service_stopped "$node" "keepalived" 10
    done

    # Restore original values
    for node in "$NODE1" "$NODE2"; do
        if [ -n "$ORIGINAL_SYNC_METHOD" ]; then
            uci_set "$node" "ha-cluster.config.sync_method" "$ORIGINAL_SYNC_METHOD"
        fi
        if [ -n "$ORIGINAL_SYNC_LEASES" ]; then
            uci_set "$node" "ha-cluster.dhcp.sync_leases" "$ORIGINAL_SYNC_LEASES"
        fi
        uci_commit "$node" "ha-cluster"
    done

    # Restart ha-cluster with restored configuration
    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" 2>/dev/null || true
    done

    # Wait for cluster to fully recover
    wait_for_cluster_healthy 30

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T21: Configuration Generation"
    info "Validates keepalived.conf correctness and stale config cleanup"

    local result=0

    # Instance naming tests (non-destructive, no setup needed)
    test_instance_name_no_vi_prefix || result=1
    test_notify_scripts_match_instance_name || result=1

    # Unicast auto-derivation tests
    test_unicast_auto_derivation || result=1
    test_multicast_no_unicast_block || result=1

    # sync_enabled filtering tests
    test_sync_enabled_filtering || result=1
    test_sync_enabled_unicast_included || result=1

    # Instance lifecycle tests
    test_new_instance_appears_in_config || result=1
    test_instance_without_vips_skipped || result=1
    test_multiple_instances_same_interface || result=1
    test_per_instance_unicast_override || result=1

    # Validation tests
    test_missing_force_rejected || result=1

    # Stale config cleanup tests (modify config, need cleanup)
    test_owsync_conf_removed_when_disabled || result=1
    test_lease_sync_conf_removed_when_disabled || result=1

    cleanup

    return $result
}

main
exit $?
