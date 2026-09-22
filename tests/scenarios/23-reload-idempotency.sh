#!/bin/sh
# 23-reload-idempotency.sh - Test T23: Reload Idempotency and Managed-Service State
#
# Regression guards for the reconciliation path taken on every
# "/etc/init.d/ha-cluster reload":
#
#   - keepalived.conf is created 0600 like the owsync/lease-sync configs
#     (it can hold the VRRP auth_pass in cleartext).
#   - A reload with an unchanged dnsmasq overlay does NOT restart dnsmasq,
#     so DNS/DHCP is not dropped needlessly.
#   - The saved standalone-service state survives a reload, so release (on
#     stop) can still restore the services to their pre-takeover state.
#   - Options set in the named "advanced" section are honoured in the
#     generated daemon configs (the section must be addressable by name).
#
# Only NODE1 is churned; NODE2 keeps the VIP during the destructive cases.
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.

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
STATE_FILE="/etc/ha-cluster/service_states"

# ============================================
# Test Cases
# ============================================

# Symbolic permission string of a file on a node (busybox has no stat(1)).
# Prints e.g. "-rw-------" from the first ls -l field.
_node_perm() {
    exec_node "$1" ls -l "$2" 2>/dev/null | awk 'NR==1 {print substr($1,1,10)}'
}

# keepalived.conf may contain the VRRP auth_pass, so it must be 0600 like
# the other generated daemon configs.
test_keepalived_conf_mode_0600() {
    subheader "keepalived.conf is created with mode 0600"
    local rc=0

    assert_eq "-rw-------" "$(_node_perm "$NODE1" "$KEEPALIVED_CONF")" \
        "keepalived.conf mode is 0600 on $NODE1" || rc=1

    # Baseline: the other two configs were already 0600.
    assert_eq "-rw-------" "$(_node_perm "$NODE1" "$OWSYNC_CONF")" \
        "owsync.conf mode is 0600 on $NODE1" || rc=1
    assert_eq "-rw-------" "$(_node_perm "$NODE1" "$LEASE_SYNC_CONF")" \
        "lease-sync.conf mode is 0600 on $NODE1" || rc=1

    return $rc
}

# A reload that does not change the dnsmasq overlay must not restart dnsmasq.
test_reload_keeps_dnsmasq_running() {
    subheader "Reload with unchanged overlay does not restart dnsmasq"
    local rc=0

    # busybox pgrep -x matches the full command line, not the comm, so use a
    # plain match and take the parent (lowest) pid; dnsmasq forks a helper.
    local pid_before pid_after
    pid_before=$(exec_node "$NODE1" sh -c 'pgrep dnsmasq | sort -n | head -n1' 2>/dev/null)

    if [ -z "$pid_before" ]; then
        fail "dnsmasq not running on $NODE1 before reload"
        return 1
    fi
    info "dnsmasq pid before reload: $pid_before"

    exec_node "$NODE1" /etc/init.d/ha-cluster reload >/dev/null 2>&1
    wait_for_cluster_healthy 30

    pid_after=$(exec_node "$NODE1" sh -c 'pgrep dnsmasq | sort -n | head -n1' 2>/dev/null)
    info "dnsmasq pid after reload: $pid_after"

    assert_eq "$pid_before" "$pid_after" \
        "dnsmasq keeps the same pid across an unchanged reload" || rc=1

    # The overlay itself must still be in place after the reload.
    local overlay
    overlay=$(exec_node "$NODE1" sh -c \
        'cat "$(find /tmp -name ha-cluster.conf 2>/dev/null | head -n1)" 2>/dev/null')
    assert_contains "$overlay" "script-on-renewal" \
        "dnsmasq HA overlay is still present after reload" || rc=1

    return $rc
}

# The pre-takeover state snapshot must not be overwritten by a reload,
# otherwise release could no longer restore the standalone services.
test_service_state_survives_reload() {
    subheader "Saved service state survives a reload"
    local rc=0

    # Start from a clean, released baseline.
    exec_node "$NODE1" /etc/init.d/ha-cluster stop >/dev/null 2>&1
    wait_for_service_stopped "$NODE1" "keepalived" 10 >/dev/null 2>&1

    # Enable a standalone service so take_over records a non-trivial state.
    exec_node "$NODE1" /etc/init.d/keepalived enable >/dev/null 2>&1

    # Take over: state file should now record keepalived as previously enabled.
    exec_node "$NODE1" /etc/init.d/ha-cluster start >/dev/null 2>&1
    wait_for_cluster_healthy 30

    local state_before
    state_before=$(get_file_content "$NODE1" "$STATE_FILE")
    assert_contains "$state_before" "keepalived=1" \
        "take_over records keepalived as previously enabled" || rc=1

    # Reload must not re-capture (which would record keepalived=0 now that
    # take_over already disabled the standalone service).
    exec_node "$NODE1" /etc/init.d/ha-cluster reload >/dev/null 2>&1
    wait_for_cluster_healthy 30

    local state_after
    state_after=$(get_file_content "$NODE1" "$STATE_FILE")
    assert_contains "$state_after" "keepalived=1" \
        "reload preserves the saved keepalived=1 state" || rc=1
    assert_eq "$state_before" "$state_after" \
        "state file is unchanged by reload" || rc=1

    return $rc
}

# Options placed in the named "advanced" section must reach the generated
# daemon configs; an anonymous section would silently fall back to defaults.
test_advanced_section_honoured() {
    subheader "Named advanced section options are honoured"

    # Use a distinctive, node-local value (lease flush cadence).
    exec_node "$NODE1" uci -q delete ha-cluster.advanced >/dev/null 2>&1
    exec_node "$NODE1" uci set ha-cluster.advanced='advanced' >/dev/null 2>&1
    exec_node "$NODE1" uci set ha-cluster.advanced.lease_sync_persist_interval='77' >/dev/null 2>&1
    exec_node "$NODE1" uci commit ha-cluster >/dev/null 2>&1

    exec_node "$NODE1" /etc/init.d/ha-cluster restart >/dev/null 2>&1
    wait_for_cluster_healthy 30

    local conf
    conf=$(get_file_content "$NODE1" "$LEASE_SYNC_CONF")
    assert_contains "$conf" "persist_interval=77" \
        "advanced.lease_sync_persist_interval reaches lease-sync.conf"
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Remove the advanced override added by the last test.
    exec_node "$NODE1" uci -q delete ha-cluster.advanced >/dev/null 2>&1
    exec_node "$NODE1" uci commit ha-cluster >/dev/null 2>&1

    # Restore the baseline: standalone keepalived disabled, no stale state,
    # ha-cluster running and managing everything.
    exec_node "$NODE1" /etc/init.d/ha-cluster stop >/dev/null 2>&1
    exec_node "$NODE1" /etc/init.d/keepalived disable >/dev/null 2>&1
    exec_node "$NODE1" rm -f "$STATE_FILE" >/dev/null 2>&1
    exec_node "$NODE1" /etc/init.d/ha-cluster start >/dev/null 2>&1

    wait_for_cluster_healthy 45
    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T23: Reload Idempotency and Managed-Service State"
    info "Guards keepalived.conf perms, dnsmasq reload stability,"
    info "service-state preservation, and advanced-section handling"

    local result=0

    # Non-destructive check first.
    test_keepalived_conf_mode_0600 || result=1

    # Reload/restart cases (each restores cluster health).
    test_reload_keeps_dnsmasq_running || result=1
    test_service_state_survives_reload || result=1
    test_advanced_section_honoured || result=1

    cleanup

    return $result
}

main
exit $?
