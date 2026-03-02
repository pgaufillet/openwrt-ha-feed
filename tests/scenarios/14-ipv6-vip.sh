#!/bin/sh
# 14-ipv6-vip.sh - Test T14: IPv6 VIP Support
#
# Validates IPv6 VIP assignment and failover.
# Requires: Dual-stack cluster (IPv6 enabled by default in docker-compose.yml)
#
# Tests IPv6 VIP support
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

# Load test framework
. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/assertions.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

# IPv6 VIP configuration (from docker-compose.yml)
VIP6_ADDRESS="${VIP6_ADDRESS:-fd00:192:168:50::254}"
VIP6_PREFIX="${VIP6_PREFIX:-64}"

# Wait for IPv6 VIP to appear anywhere
# Usage: wait_for_vip6_anywhere [timeout]
wait_for_vip6_anywhere() {
    local timeout="${1:-30}"
    local count=0

    while [ $count -lt "$timeout" ]; do
        VIP6_OWNER=$(get_vip6_owner)
        if [ -n "$VIP6_OWNER" ]; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    VIP6_OWNER=""
    return 1
}

# ============================================
# Pre-flight Checks
# ============================================

check_ipv6_enabled() {
    subheader "IPv6 Support Check"

    # Check if IPv6 is enabled on node1
    local has_ipv6
    has_ipv6=$(exec_node "$NODE1" cat /proc/net/if_inet6 2>/dev/null | wc -l)

    if [ "$has_ipv6" -gt 0 ]; then
        pass "IPv6 enabled on $NODE1"
    else
        skip "IPv6 not enabled in kernel"
        exit 0
    fi

    # Check if nodes have IPv6 addresses
    local node1_ip6 node2_ip6
    node1_ip6=$(exec_node "$NODE1" ip -6 addr show scope global 2>/dev/null | grep "fd00:" | head -1)
    node2_ip6=$(exec_node "$NODE2" ip -6 addr show scope global 2>/dev/null | grep "fd00:" | head -1)

    if [ -n "$node1_ip6" ] && [ -n "$node2_ip6" ]; then
        pass "Both nodes have global IPv6 addresses"
        debug "$NODE1: $node1_ip6"
        debug "$NODE2: $node2_ip6"
    else
        skip "Nodes don't have global IPv6 addresses"
        exit 0
    fi
}

check_ipv6_connectivity() {
    subheader "IPv6 Connectivity Check"

    # Try to ping node2 from node1 using IPv6
    if exec_node "$NODE1" ping6 -c 1 -W 2 fd00:172:30::11 >/dev/null 2>&1; then
        pass "IPv6 connectivity between nodes"
    else
        warn "IPv6 ping failed, but continuing (may work with VIP)"
    fi
}

# ============================================
# Test Cases
# ============================================

test_configure_ipv6_vip() {
    subheader "Configure IPv6 VIP"

    # Check if VIP6_ADDRESS env var was set
    local node1_vip6
    node1_vip6=$(exec_node "$NODE1" sh -c 'echo $VIP6_ADDRESS' 2>/dev/null)

    if [ -z "$node1_vip6" ]; then
        info "VIP6_ADDRESS not set, configuring manually"
        node1_vip6="$VIP6_ADDRESS"
    fi

    # Configure IPv6 VIP on both nodes via UCI
    for node in "$NODE1" "$NODE2"; do
        # Add IPv6 VIP to ha-cluster config
        exec_node "$node" uci set ha-cluster.lan.address6="$VIP6_ADDRESS" 2>/dev/null || true
        exec_node "$node" uci set ha-cluster.lan.prefix6="$VIP6_PREFIX" 2>/dev/null || true
        exec_node "$node" uci commit ha-cluster 2>/dev/null || true
    done

    # Restart ha-cluster to apply changes
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
    done

    # Wait for services to restart
    sleep 5

    pass "IPv6 VIP configured: $VIP6_ADDRESS/$VIP6_PREFIX"
}

test_ipv6_vip_assigned() {
    subheader "IPv6 VIP Assignment"

    # Wait for IPv6 VIP to be assigned
    if wait_for_vip6_anywhere 30; then
        pass "IPv6 VIP ($VIP6_ADDRESS) assigned to $VIP6_OWNER"
    else
        fail "IPv6 VIP ($VIP6_ADDRESS) not assigned to any node"
        info "IPv6 addresses on nodes:"
        for node in $(get_active_nodes); do
            info "$node:"
            exec_node "$node" ip -6 addr show scope global 2>&1 || echo "(failed)"
        done
        return 1
    fi
}

test_ipv6_vip_on_master() {
    subheader "IPv6 VIP on MASTER Only"

    local ipv4_owner ipv6_owner
    ipv4_owner=$(get_vip_owner)
    ipv6_owner=$(get_vip6_owner)

    info "IPv4 VIP owner: $ipv4_owner"
    info "IPv6 VIP owner: $ipv6_owner"

    if [ "$ipv4_owner" = "$ipv6_owner" ]; then
        pass "Both IPv4 and IPv6 VIPs on same node ($ipv4_owner)"
    else
        fail "VIP mismatch: IPv4 on $ipv4_owner, IPv6 on $ipv6_owner"
        return 1
    fi

    # Verify BACKUP doesn't have IPv6 VIP
    for node in $(get_active_nodes); do
        if [ "$node" = "$ipv6_owner" ]; then
            continue
        fi
        if has_vip6 "$node"; then
            fail "$node (BACKUP) should not have IPv6 VIP"
            return 1
        fi
    done

    pass "IPv6 VIP correctly absent from BACKUP nodes"
}

test_ipv6_failover() {
    subheader "IPv6 VIP Failover"

    local initial_owner
    initial_owner=$(get_vip6_owner)

    if [ -z "$initial_owner" ]; then
        fail "No IPv6 VIP owner at start of failover test"
        return 1
    fi

    # Determine expected failover target
    local failover_target
    if [ "$initial_owner" = "$NODE1" ]; then
        failover_target="$NODE2"
    else
        failover_target="$NODE1"
    fi

    info "Stopping keepalived on $initial_owner (current IPv6 VIP owner)"

    # Record failover start time (target: < 3 seconds)
    local failover_start
    failover_start=$(date +%s%3N)  # milliseconds since epoch

    service_stop "$initial_owner" "keepalived"

    # Wait for IPv6 VIP failover and measure time
    if wait_for_vip6 "$failover_target" "$FAILOVER_TIMEOUT"; then
        local failover_end
        failover_end=$(date +%s%3N)

        # Calculate failover time in milliseconds
        local failover_time_ms=$((failover_end - failover_start))
        local failover_time_sec=$((failover_time_ms / 1000))
        local failover_time_decimal=$((failover_time_ms % 1000))

        info "IPv6 VIP failover time: ${failover_time_sec}.$(printf "%03d" $failover_time_decimal)s"
        pass "IPv6 VIP failed over to $failover_target"

        # Validate against failover time target (< 3 seconds)
        if [ "$failover_time_ms" -lt 3000 ]; then
            pass "Failover time within target (< 3s)"
        else
            fail "Failover time ${failover_time_sec}.$(printf "%03d" $failover_time_decimal)s exceeds target (< 3s)"
            return 1
        fi
    else
        local new_owner
        new_owner=$(get_vip6_owner)
        fail "IPv6 VIP should have moved to $failover_target, but is on ${new_owner:-none}"
        return 1
    fi

    # Verify IPv4 VIP also moved
    local ipv4_owner
    ipv4_owner=$(get_vip_owner)

    if [ "$ipv4_owner" = "$failover_target" ]; then
        pass "IPv4 VIP also on failover target ($failover_target)"
    else
        warn "IPv4 VIP on $ipv4_owner, IPv6 VIP on $failover_target (mismatch)"
    fi
}

test_ipv6_recovery() {
    subheader "IPv6 VIP Recovery"

    # Restart keepalived on the node we stopped
    local stopped_node
    if ! service_running "$NODE1" "keepalived"; then
        stopped_node="$NODE1"
    else
        stopped_node="$NODE2"
    fi

    info "Restarting keepalived on $stopped_node"
    service_start "$stopped_node" "keepalived"

    if wait_for_service "$stopped_node" "keepalived" 10; then
        pass "Keepalived restarted on $stopped_node"
    else
        fail "Keepalived failed to restart on $stopped_node"
        return 1
    fi

    # Wait for VRRP to stabilize
    sleep 5

    # Verify cluster is healthy
    local ipv4_owner ipv6_owner
    ipv4_owner=$(get_vip_owner)
    ipv6_owner=$(get_vip6_owner)

    if [ -n "$ipv4_owner" ] && [ -n "$ipv6_owner" ]; then
        pass "Cluster recovered: IPv4 VIP on $ipv4_owner, IPv6 VIP on $ipv6_owner"
    else
        fail "Cluster not healthy after recovery"
        return 1
    fi

    # Both VIPs should be on the same node
    if [ "$ipv4_owner" = "$ipv6_owner" ]; then
        pass "Both VIPs on same node after recovery"
    else
        warn "VIP split: IPv4 on $ipv4_owner, IPv6 on $ipv6_owner"
    fi

    check_no_split_brain
}

# ============================================
# Main
# ============================================

main() {
    header "T14: IPv6 VIP Support"
    info "Validates IPv6 VIP assignment and failover"

    check_ipv6_enabled
    check_ipv6_connectivity

    test_configure_ipv6_vip || return 1
    test_ipv6_vip_assigned || return 1
    test_ipv6_vip_on_master || return 1
    test_ipv6_failover || return 1
    test_ipv6_recovery || return 1

    return 0
}

main
exit $?
