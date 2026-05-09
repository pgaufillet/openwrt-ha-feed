#!/bin/sh
# 23-dhcpv6-backup-guard.sh - Regression test for DHCPv6 BACKUP suppression
#
# Validates that a node which was temporary MASTER and then returns to BACKUP
# does not answer DHCPv6 client traffic and does not publish local DHCPv6 lease
# events back into lease-sync.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/assertions.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

CLIENT1="ha-client1"
IPV6_VIP="fd00:192:168:50::fe"

setup() {
    subheader "Test Setup"

    if ! client_running "$CLIENT1"; then
        skip "DHCPv6 BACKUP guard test" "$CLIENT1 container not running"
        return 1
    fi

    save_and_disable_odhcpd_all || return 1

    for node in "$NODE1" "$NODE2"; do
        uci_set "$node" "ha-cluster.lan.address6" "$IPV6_VIP"
        uci_set "$node" "ha-cluster.lan.prefix6" "64"
        uci_commit "$node" "ha-cluster"
        exec_node "$node" /etc/init.d/ha-cluster restart >/dev/null 2>&1 || true
    done

    if ! wait_for_cluster_healthy 30; then
        fail "Cluster did not become healthy with IPv6 VRRP enabled"
        return 1
    fi

    pass "Test setup complete"
}

force_secondary_master_then_backup() {
    subheader "Force Secondary MASTER Then BACKUP"

    stop_ha_cluster "$NODE1" >/dev/null 2>&1 || true

    if wait_for_vip "$NODE2" 30; then
        pass "$NODE2 became temporary MASTER"
    else
        fail "$NODE2 did not become temporary MASTER"
        return 1
    fi

    start_ha_cluster "$NODE1" >/dev/null 2>&1 || true

    if wait_for_vip "$NODE1" 30; then
        pass "$NODE1 reclaimed MASTER"
    else
        fail "$NODE1 did not reclaim MASTER"
        return 1
    fi

    sleep 3

    if [ "$(get_vrrp_state "$NODE2")" = "BACKUP" ]; then
        pass "$NODE2 is BACKUP after primary returns"
    else
        fail "$NODE2 is not BACKUP after primary returns"
        print_cluster_status
        return 1
    fi
}

test_guard_rule_installed() {
    subheader "DHCPv6 Guard Rule Check"

    if exec_node "$NODE2" nft list chain inet ha_cluster_dhcpv6 input 2>/dev/null | grep -q "udp dport 547"; then
        pass "DHCPv6 guard input chain exists"
    else
        fail "DHCPv6 guard input chain missing"
        exec_node "$NODE2" nft list ruleset 2>/dev/null | grep -A8 ha_cluster_dhcpv6 || true
        return 1
    fi

    if exec_node "$NODE2" nft list set inet ha_cluster_dhcpv6 backup_ifaces 2>/dev/null | grep -q "lan"; then
        pass "$NODE2 blocks DHCPv6 input on LAN while BACKUP"
    else
        fail "$NODE2 backup_ifaces set does not contain LAN"
        exec_node "$NODE2" nft list table inet ha_cluster_dhcpv6 2>/dev/null || true
        return 1
    fi
}

test_backup_does_not_answer_dhcpv6() {
    subheader "BACKUP Must Not Answer DHCPv6"

    dhcpv6_release "$CLIENT1" 2>/dev/null || true

    exec_node "$NODE2" logread -c >/dev/null 2>&1 || true
    exec_node "$NODE2" rm -f /tmp/backup_dhcp_events.log /tmp/backup_dhcp_events.pid 2>/dev/null || true
    exec_node "$NODE2" sh -c 'timeout 30 ubus listen dhcp.lease > /tmp/backup_dhcp_events.log 2>&1 & echo $! > /tmp/backup_dhcp_events.pid'
    sleep 1

    local client_ipv6
    client_ipv6=$(dhcpv6_request "$CLIENT1")
    sleep 5

    exec_node "$NODE2" sh -c 'kill "$(cat /tmp/backup_dhcp_events.pid 2>/dev/null)" 2>/dev/null || true'

    if [ -n "$client_ipv6" ]; then
        pass "$CLIENT1 obtained DHCPv6 lease from active MASTER: $client_ipv6"
    else
        fail "$CLIENT1 did not obtain DHCPv6 lease from active MASTER"
        return 1
    fi

    local bad_logs
    bad_logs=$(exec_node "$NODE2" sh -c "logread | grep -E 'dnsmasq-dhcp: (DHCPSOLICIT|DHCPREQUEST|DHCPREPLY).*\\(lan\\)|lease-sync: Processed local lease|lease-sync-hotplug: (add|update|remove) event .* published'" 2>/dev/null || true)

    if [ -z "$bad_logs" ]; then
        pass "$NODE2 did not receive/respond/publish local DHCPv6 lease events while BACKUP"
    else
        fail "$NODE2 processed DHCPv6 locally while BACKUP"
        echo "$bad_logs"
        return 1
    fi

    local events
    events=$(exec_node "$NODE2" cat /tmp/backup_dhcp_events.log 2>/dev/null || true)
    if echo "$events" | grep -q "\"node_id\":\"$NODE2\""; then
        fail "$NODE2 published local dhcp.lease events while BACKUP"
        echo "$events"
        return 1
    fi

    pass "$NODE2 did not publish local dhcp.lease events while BACKUP"
}

cleanup() {
    subheader "Cleanup"

    dhcpv6_release "$CLIENT1" 2>/dev/null || true

    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" sh -c "uci -q delete ha-cluster.lan.address6; uci -q delete ha-cluster.lan.prefix6; uci commit ha-cluster" 2>/dev/null || true
        exec_node "$node" rm -f /tmp/backup_dhcp_events.log /tmp/backup_dhcp_events.pid 2>/dev/null || true
        exec_node "$node" /etc/init.d/ha-cluster restart >/dev/null 2>&1 || true
    done

    restore_odhcpd_if_was_running
    pass "Cleanup complete"
}

main() {
    header "T23: DHCPv6 BACKUP Guard"
    info "Validates that BACKUP nodes do not answer DHCPv6 or publish local DHCPv6 leases"

    local result=0

    setup || return 0
    force_secondary_master_then_backup || result=1
    test_guard_rule_installed || result=1
    test_backup_does_not_answer_dhcpv6 || result=1
    cleanup

    return $result
}

main
exit $?
