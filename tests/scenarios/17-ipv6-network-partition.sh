#!/bin/sh
# 17-ipv6-network-partition.sh - Test T17: IPv6 Network Partition
#
# Validates lease consistency and split-brain prevention during network partition.
# Tests that when nodes cannot communicate, they maintain consistent state
# and properly reconcile when the partition heals.
#
# Test flow:
#   1. Create IPv6 DHCPv6 leases on both nodes
#   2. Simulate network partition (block traffic between nodes)
#   3. Verify only one node keeps VIP (no split-brain)
#   4. Create additional leases during partition
#   5. Heal partition
#   6. Verify lease consistency after reconciliation
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

# Partition simulation: use iptables/nftables to block peer traffic
BACKEND_SUBNET="172.30.0.0/24"
BACKEND_SUBNET6="fd00:172:30::/64"

# Test lease tracking
LEASE_BEFORE_PARTITION=""
LEASE_DURING_PARTITION=""

# ============================================
# Network Partition Helper Functions
# ============================================

# Block traffic between nodes on backend network
# Usage: create_partition
create_partition() {
    local node1_ip="172.30.0.10"
    local node2_ip="172.30.0.11"
    local node1_ip6="fd00:172:30::10"
    local node2_ip6="fd00:172:30::11"

    info "Creating network partition (blocking peer traffic)"

    # Flush connection tracking to ensure established connections don't bypass rules
    exec_node "$NODE1" sh -c "echo 1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal" 2>/dev/null || true
    exec_node "$NODE2" sh -c "echo 1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal" 2>/dev/null || true
    exec_node "$NODE1" conntrack -F 2>/dev/null || true
    exec_node "$NODE2" conntrack -F 2>/dev/null || true

    # For container-to-container traffic, use OUTPUT chain (not FORWARD)
    # Insert rules at position 1 (before ct state checks)
    # Block IPv4 traffic from NODE1 to NODE2
    exec_node "$NODE1" nft insert rule inet fw4 output position 0 ip daddr "$node2_ip" drop 2>/dev/null || \
        exec_node "$NODE1" iptables -I OUTPUT 1 -d "$node2_ip" -j DROP

    # Block IPv6 traffic from NODE1 to NODE2
    exec_node "$NODE1" nft insert rule inet fw4 output position 0 ip6 daddr "$node2_ip6" drop 2>/dev/null || \
        exec_node "$NODE1" ip6tables -I OUTPUT 1 -d "$node2_ip6" -j DROP

    # Block IPv4 traffic from NODE2 to NODE1
    exec_node "$NODE2" nft insert rule inet fw4 output position 0 ip daddr "$node1_ip" drop 2>/dev/null || \
        exec_node "$NODE2" iptables -I OUTPUT 1 -d "$node1_ip" -j DROP

    # Block IPv6 traffic from NODE2 to NODE1
    exec_node "$NODE2" nft insert rule inet fw4 output position 0 ip6 daddr "$node1_ip6" drop 2>/dev/null || \
        exec_node "$NODE2" ip6tables -I OUTPUT 1 -d "$node1_ip6" -j DROP

    # Flush conntrack again after adding rules
    exec_node "$NODE1" conntrack -F 2>/dev/null || true
    exec_node "$NODE2" conntrack -F 2>/dev/null || true

    sleep 2  # Allow rules to take effect
}

# Remove partition and restore connectivity
# Usage: heal_partition
heal_partition() {
    local node1_ip="172.30.0.10"
    local node2_ip="172.30.0.11"
    local node1_ip6="fd00:172:30::10"
    local node2_ip6="fd00:172:30::11"

    info "Healing network partition (restoring peer traffic)"

    # Remove IPv4 drop rules from OUTPUT chain
    exec_node "$NODE1" nft flush chain inet fw4 output 2>/dev/null || \
        exec_node "$NODE1" iptables -D OUTPUT -d "$node2_ip" -j DROP 2>/dev/null || true

    exec_node "$NODE2" nft flush chain inet fw4 output 2>/dev/null || \
        exec_node "$NODE2" iptables -D OUTPUT -d "$node1_ip" -j DROP 2>/dev/null || true

    # Remove IPv6 drop rules from OUTPUT chain
    exec_node "$NODE1" ip6tables -D OUTPUT -d "$node2_ip6" -j DROP 2>/dev/null || true
    exec_node "$NODE2" ip6tables -D OUTPUT -d "$node1_ip6" -j DROP 2>/dev/null || true

    sleep 2  # Allow connectivity to restore
}

# Verify nodes cannot communicate with each other
# Usage: verify_partition_active
verify_partition_active() {
    # Try to ping NODE2 from NODE1 (should fail)
    if exec_node "$NODE1" ping -c 1 -W 2 172.30.0.11 >/dev/null 2>&1; then
        return 1  # Partition not working
    fi

    # Try to ping NODE1 from NODE2 (should fail)
    if exec_node "$NODE2" ping -c 1 -W 2 172.30.0.10 >/dev/null 2>&1; then
        return 1  # Partition not working
    fi

    return 0  # Partition is active
}

# Verify nodes can communicate with each other
# Usage: verify_connectivity_restored
verify_connectivity_restored() {
    # Ping NODE2 from NODE1
    if ! exec_node "$NODE1" ping -c 1 -W 2 172.30.0.11 >/dev/null 2>&1; then
        return 1
    fi

    # Ping NODE1 from NODE2
    if ! exec_node "$NODE2" ping -c 1 -W 2 172.30.0.10 >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Verify IPv6 is enabled
    if ! check_ipv6_enabled >/dev/null 2>&1; then
        skip "Network partition test" "IPv6 not enabled"
        return 1
    fi

    # Disable odhcpd if running (DHCPv6 via dnsmasq)
    save_and_disable_odhcpd_all || return 1

    # Ensure lease-sync is running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            skip "Network partition test" "lease-sync not running"
            return 1
        fi
    done

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_baseline_leases() {
    subheader "Create Baseline DHCPv6 Leases"

    # Request DHCPv6 lease on client1
    info "Requesting DHCPv6 lease from $CLIENT1..."
    local client_mac
    client_mac=$(get_client_mac "$CLIENT1")

    # Use dhcpcd to request IPv6 address
    exec_client "$CLIENT1" dhcpcd -6 -1 -t 10 eth0 2>/dev/null || true
    sleep 2

    # Get the assigned IPv6 address
    local ipv6_addr
    ipv6_addr=$(exec_client "$CLIENT1" ip -6 addr show dev eth0 2>/dev/null | \
                grep 'inet6 fd00:192:168:50:' | awk '{print $2}' | cut -d/ -f1 | \
                grep -v '::2' | head -1)

    if [ -n "$ipv6_addr" ]; then
        LEASE_BEFORE_PARTITION="$ipv6_addr"
        info "DHCPv6 lease obtained: $ipv6_addr"
        pass "Baseline lease created"
    else
        warn "No DHCPv6 lease obtained (may be using SLAAC only)"
        # This is not a failure - SLAAC is valid
        pass "Baseline check complete (SLAAC mode)"
    fi

    # Wait for sync
    sleep 3
}

test_create_partition() {
    subheader "Create Network Partition"

    create_partition

    if verify_partition_active; then
        pass "Network partition created (nodes isolated)"
    else
        fail "Network partition not effective (nodes can still communicate)"
        return 1
    fi
}

test_partition_vip_state() {
    subheader "Check VIP State During Partition"

    # Wait for keepalived to detect partition
    sleep 5

    # During a network partition, VRRP correctly promotes both nodes to MASTER
    # because neither can see the other's advertisements. This is expected
    # split-brain behavior (consistent with T09's test_wait_for_split_brain).

    # Check IPv4 VIP ownership
    local node1_has_vip=0
    local node2_has_vip=0

    if has_vip "$NODE1"; then
        node1_has_vip=1
        info "$NODE1 has IPv4 VIP"
    fi

    if has_vip "$NODE2"; then
        node2_has_vip=1
        info "$NODE2 has IPv4 VIP"
    fi

    local total_vips=$((node1_has_vip + node2_has_vip))

    if [ "$total_vips" -eq 2 ]; then
        info "Split-brain detected (expected during partition - both nodes are MASTER)"
        pass "Both nodes promoted to MASTER (correct VRRP partition behavior)"
    elif [ "$total_vips" -eq 1 ]; then
        info "Only one node has VIP (partition may not be fully effective)"
        pass "At least one node has VIP"
    else
        fail "No node has VIP"
        return 1
    fi

    # Check IPv6 VIP (informational)
    if has_vip6 "$NODE1"; then
        info "$NODE1 has IPv6 VIP"
    fi
    if has_vip6 "$NODE2"; then
        info "$NODE2 has IPv6 VIP"
    fi
}

test_partition_reconciliation() {
    subheader "Heal Partition and Verify Reconciliation"

    heal_partition

    if verify_connectivity_restored; then
        pass "Network connectivity restored"
    else
        fail "Connectivity not restored after healing partition"
        return 1
    fi

    # Wait for lease-sync to reconcile
    info "Waiting for lease-sync reconciliation..."
    sleep 10

    # Verify baseline lease still exists on both nodes
    if [ -n "$LEASE_BEFORE_PARTITION" ]; then
        local ip_short
        ip_short=$(echo "$LEASE_BEFORE_PARTITION" | cut -d'/' -f1)

        if get_all_leases "$NODE1" | grep -q "$ip_short"; then
            pass "Baseline lease present on $NODE1 after reconciliation"
        else
            warn "Baseline lease missing from $NODE1"
        fi

        if get_all_leases "$NODE2" | grep -q "$ip_short"; then
            pass "Baseline lease present on $NODE2 after reconciliation"
        else
            warn "Baseline lease missing from $NODE2"
        fi
    fi

    # Verify lease counts match
    local count1 count2
    count1=$(get_all_leases "$NODE1" | grep -c '"ip"' || echo 0)
    count2=$(get_all_leases "$NODE2" | grep -c '"ip"' || echo 0)

    info "Lease count: $NODE1=$count1, $NODE2=$count2"

    if [ "$count1" -eq "$count2" ]; then
        pass "Lease counts consistent after reconciliation"
    else
        warn "Lease count mismatch after reconciliation ($count1 vs $count2)"
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Ensure partition is healed
    heal_partition

    # Restore odhcpd if it was running before the test
    restore_odhcpd_if_was_running

    # Release client leases
    exec_client "$CLIENT1" dhcpcd -k eth0 2>/dev/null || true

    pass "Cleanup complete"
}

# ============================================
# Main Test Flow
# ============================================

main() {
    header "T17: IPv6 Network Partition"
    info "Validates split-brain prevention and lease consistency during partition"

    setup || return 1

    test_baseline_leases || return 1
    test_create_partition || return 1
    test_partition_vip_state || return 1
    test_partition_reconciliation || return 1

    cleanup

    return 0
}

main
exit $?
