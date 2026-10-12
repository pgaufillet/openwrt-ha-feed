#!/bin/sh
# 27-standalone-lease-sync.sh - Test T27: Standalone lease-sync
#
# Validates the lease-sync package's own init script, used without
# ha-cluster:
#   - with a PSK in /etc/config/lease-sync, the daemon starts and stays
#     up (same pid over a window longer than procd's respawn delay)
#   - the generated config holds the key, is readable by root only, and
#     the key never reaches the syslog
#   - a lease served by one node reaches the other
#   - when ha-cluster stops and hands UDP 5378 back to the standalone
#     daemon, its own daemon exits before the standalone service is
#     restored and binds the port: no sample shows two holders
#
# Both nodes run ha-cluster on entry; the cleanup restores
# /etc/config/lease-sync and restarts ha-cluster.
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

LEASE_SYNC_INIT="/etc/init.d/lease-sync"
LEASE_SYNC_UCI="/etc/config/lease-sync"
LEASE_SYNC_UCI_SAVED="/tmp/lease-sync.uci.saved"
LEASE_SYNC_CONF="/etc/lease-sync/config"
SYNC_PORT=5378
CLIENT1="ha-client1"
NODE1_SERVER="192.168.50.10"

# Longer than procd's respawn delay (5 s), so that a crash loop shows
STABLE_WINDOW=16

# Lease requested in test_lease_replicated, removed by the cleanup
TEST_LEASE_IP=""

# ============================================
# Helpers
# ============================================

# Pid of a running procd instance, empty when not running
# Usage: pid=$(instance_pid "node" "service" "instance")
instance_pid() {
    exec_node "$1" sh -c "ubus call service list '{\"name\":\"$2\"}' |
        jsonfilter -e '@[\"$2\"].instances[\"$3\"].pid'" 2>/dev/null
}

# Usage: peer_ip "node"
peer_ip() {
    if [ "$1" = "$NODE1" ]; then
        echo "$NODE2_BACKEND_IP"
    else
        echo "$NODE1_BACKEND_IP"
    fi
}

# Epoch timestamp of the first syslog line (logread -t) matching a pattern
# Usage: log_since "node" "$t0" | _log_ts "pattern"
_log_ts() {
    grep "$1" | head -n1 | sed -n 's/^[^[]*\[\([0-9.]*\)\].*/\1/p'
}

# Request a one-shot lease from a single server
# Usage: ip=$(request_pinned_lease "ha-client1" "192.168.50.10")
request_pinned_lease() {
    exec_client "$1" sh -c 'killall -9 dhcpcd; ip addr flush dev eth0; rm -rf /var/lib/dhcpcd/*' >/dev/null 2>&1
    exec_client "$1" dhcpcd -4 -1 -t 20 --whitelist "$2" eth0 >/dev/null 2>&1
    get_client_ip "$1"
}

# ============================================
# Test Setup
# ============================================

# Returns 2 when the scenario does not apply
setup() {
    subheader "Test Setup"

    local node
    for node in "$NODE1" "$NODE2"; do
        if ! file_exists_on_node "$node" "$LEASE_SYNC_INIT"; then
            skip "Standalone lease-sync" "$LEASE_SYNC_INIT not installed on $node"
            return 2
        fi
    done

    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" >/dev/null 2>&1 || true
    done
    for node in "$NODE1" "$NODE2"; do
        if ! wait_for "lease-sync gone on $node" 20 \
                "! exec_node $node pidof lease-sync >/dev/null"; then
            fail "lease-sync still running on $node after stopping ha-cluster"
            return 1
        fi
    done

    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" sh -c "
            cp $LEASE_SYNC_UCI $LEASE_SYNC_UCI_SAVED
            uci set lease-sync.config.enabled='1'
            uci -q delete lease-sync.config.peer
            uci add_list lease-sync.config.peer='$(peer_ip "$node")'
            uci set lease-sync.config.security_mode='encrypted'
            uci set lease-sync.config.psk_key='$TEST_KEY'
            uci commit lease-sync
        "
    done

    pass "ha-cluster stopped, standalone lease-sync configured with a PSK"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_standalone_starts() {
    subheader "Standalone daemon starts and stays up"
    local rc=0 node t0 pid first i

    for node in "$NODE1" "$NODE2"; do
        t0=$(exec_node "$node" date +%s)
        exec_node "$node" "$LEASE_SYNC_INIT" restart >/dev/null 2>&1

        sleep 2
        first=$(instance_pid "$node" lease-sync lease-sync)
        i=0
        pid="$first"
        while [ -n "$first" ] && [ "$pid" = "$first" ] && [ $i -lt "$STABLE_WINDOW" ]; do
            sleep 2
            i=$((i + 2))
            pid=$(instance_pid "$node" lease-sync lease-sync)
        done
        if [ -n "$first" ] && [ "$pid" = "$first" ]; then
            pass "$node: lease-sync running with pid $first for ${STABLE_WINDOW}s"
        else
            fail "$node: lease-sync not stable (pid ${first:-none}, then ${pid:-none} after ${i}s)"
            log_since "$node" "$t0" | grep 'lease-sync\[' | tail -n 20
            rc=1
            continue
        fi

        if log_since "$node" "$t0" | grep -q "lease-sync\[$first\]: Peer sync initialized"; then
            pass "$node: peer sync initialized"
        else
            fail "$node: no 'Peer sync initialized' from lease-sync[$first]"
            rc=1
        fi
        if log_since "$node" "$t0" | grep -q "SECURITY ERROR"; then
            fail "$node: lease-sync reported a security error"
            log_since "$node" "$t0" | grep 'lease-sync\[' | grep -A3 "SECURITY ERROR" | head -n 8
            rc=1
        fi
    done

    return $rc
}

test_config_protected() {
    subheader "Generated config holds the key, readable by root only"
    local rc=0 node mode

    for node in "$NODE1" "$NODE2"; do
        if exec_node "$node" grep -qx "psk_key=$TEST_KEY" "$LEASE_SYNC_CONF"; then
            pass "$node: $LEASE_SYNC_CONF holds psk_key"
        else
            fail "$node: $LEASE_SYNC_CONF does not hold psk_key"
            rc=1
        fi

        mode=$(exec_node "$node" ls -l "$LEASE_SYNC_CONF" 2>/dev/null | cut -d' ' -f1)
        assert_eq "-rw-------" "$mode" "$node: $LEASE_SYNC_CONF mode" || rc=1

        if exec_node "$node" sh -c "logread | grep -qF '$TEST_KEY'"; then
            fail "$node: psk_key found in the syslog"
            rc=1
        else
            pass "$node: psk_key not in the syslog"
        fi
    done

    return $rc
}

test_lease_replicated() {
    subheader "Lease served by $NODE1 reaches $NODE2"

    if ! client_running "$CLIENT1"; then
        fail "$CLIENT1 container not running"
        return 1
    fi

    TEST_LEASE_IP=$(request_pinned_lease "$CLIENT1" "$NODE1_SERVER")
    if [ -z "$TEST_LEASE_IP" ]; then
        fail "$CLIENT1 got no lease from $NODE1"
        return 1
    fi
    if ! wait_for_lease "$NODE1" "$TEST_LEASE_IP" 10; then
        fail "Lease $TEST_LEASE_IP not in $NODE1's lease file"
        return 1
    fi
    if wait_for_lease "$NODE2" "$TEST_LEASE_IP" "$SYNC_TIMEOUT"; then
        pass "Lease $TEST_LEASE_IP replicated to $NODE2"
    else
        fail "Lease $TEST_LEASE_IP not replicated to $NODE2 within ${SYNC_TIMEOUT}s"
        return 1
    fi
}

# ha-cluster's stop restores the standalone service it took over, which
# binds the same UDP port. The daemon binds with SO_REUSEADDR, so a
# start before ha-cluster's daemon exits succeeds and both hold the port.
test_handover_on_stop() {
    subheader "ha-cluster stop hands the port to the standalone daemon"
    local rc=0 node ha_pid standalone_pid t0 result samples max holders

    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" >/dev/null 2>&1 || true
    done
    if ! wait_for "ha-cluster's lease-sync on $NODE1" 20 \
            "[ -n \"\$(instance_pid $NODE1 ha-cluster lease-sync)\" ]"; then
        fail "ha-cluster did not start lease-sync on $NODE1"
        return 1
    fi
    ha_pid=$(instance_pid "$NODE1" ha-cluster lease-sync)
    if [ -n "$(instance_pid "$NODE1" lease-sync lease-sync)" ]; then
        fail "$NODE1: ha-cluster did not take the standalone lease-sync over"
        return 1
    fi
    info "$NODE1: ha-cluster's lease-sync pid $ha_pid, standalone stopped"

    # Sample the holders of the port while the stop runs, as fast as
    # netstat allows (BusyBox sleep takes whole seconds)
    t0=$(exec_node "$NODE1" date +%s)
    result=$(exec_node "$NODE1" sh -c "
        /etc/init.d/ha-cluster stop >/dev/null 2>&1 &
        stopper=\$!
        end=\$((\$(date +%s) + 20))
        samples=0 max=0 holders=''
        while [ \"\$(date +%s)\" -lt \"\$end\" ]; do
            pids=\$(netstat -ulnp 2>/dev/null |
                awk '\$4 ~ /:$SYNC_PORT\$/ { split(\$NF, a, \"/\"); print a[1] }' | sort -u)
            n=\$(echo \"\$pids\" | grep -c .)
            samples=\$((samples + 1))
            [ \"\$n\" -gt \"\$max\" ] && { max=\$n; holders=\$(echo \$pids); }
        done
        wait \$stopper
        echo \"\$samples \$max \$holders\"
    ")
    samples=${result%% *}
    max=$(echo "$result" | cut -d' ' -f2)
    holders=$(echo "$result" | cut -d' ' -f3-)
    info "$NODE1: $samples samples of UDP $SYNC_PORT, at most $max holder(s) ($holders)"
    if [ "${samples:-0}" -gt 0 ] && [ "${max:-9}" -le 1 ]; then
        pass "$NODE1: at most one lease-sync held UDP $SYNC_PORT during the stop"
    else
        fail "$NODE1: $max lease-sync processes held UDP $SYNC_PORT at once ($holders)"
        rc=1
    fi

    standalone_pid=$(instance_pid "$NODE1" lease-sync lease-sync)
    if [ -z "$standalone_pid" ]; then
        fail "$NODE1: standalone lease-sync not running after the stop"
        log_since "$NODE1" "$t0" | grep 'lease-sync\[' | tail -n 20
        return 1
    fi

    # A standalone start made too early may still bind after ha-cluster's
    # daemon exits, procd ending it within milliseconds: the samples and
    # the bind order can miss it, the release order cannot.
    local exit_ts release_ts init_ts
    exit_ts=$(log_since "$NODE1" "$t0" | _log_ts "lease-sync\[$ha_pid\]: lease-sync daemon terminated")
    release_ts=$(log_since "$NODE1" "$t0" | _log_ts "ha-cluster: Releasing service management")
    init_ts=$(log_since "$NODE1" "$t0" | grep -v "lease-sync\[$ha_pid\]" |
        _log_ts "lease-sync\[[0-9]*\]: Peer sync initialized")
    info "ha-cluster's lease-sync exit: ${exit_ts:-none}, release: ${release_ts:-none}, standalone init: ${init_ts:-none}"
    if [ -n "$exit_ts" ] && [ -n "$release_ts" ] &&
       awk -v e="$exit_ts" -v r="$release_ts" 'BEGIN { exit !(e < r) }'; then
        pass "$NODE1: ha-cluster's lease-sync exited before the standalone services were restored"
    else
        fail "$NODE1: ha-cluster's lease-sync exited before the standalone services were restored"
        rc=1
    fi
    if [ -n "$exit_ts" ] && [ -n "$init_ts" ] &&
       awk -v e="$exit_ts" -v s="$init_ts" 'BEGIN { exit !(e < s) }'; then
        pass "$NODE1: ha-cluster's lease-sync exited before the standalone one bound the port"
    else
        fail "$NODE1: ha-cluster's lease-sync exited before the standalone one bound the port"
        rc=1
    fi

    return $rc
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup: restoring ha-cluster"
    local node

    exec_client "$CLIENT1" sh -c 'killall -9 dhcpcd; ip addr flush dev eth0; rm -rf /var/lib/dhcpcd/*' >/dev/null 2>&1

    for node in "$NODE1" "$NODE2"; do
        stop_ha_cluster "$node" >/dev/null 2>&1 || true
        exec_node "$node" "$LEASE_SYNC_INIT" stop >/dev/null 2>&1 || true
        if [ -n "$TEST_LEASE_IP" ]; then
            delete_lease "$node" "$TEST_LEASE_IP" >/dev/null 2>&1 || true
        fi
        exec_node "$node" sh -c "
            [ -f $LEASE_SYNC_UCI_SAVED ] && mv $LEASE_SYNC_UCI_SAVED $LEASE_SYNC_UCI
            rm -f $LEASE_SYNC_CONF
        "
    done

    for node in "$NODE1" "$NODE2"; do
        start_ha_cluster "$node" >/dev/null 2>&1 || true
    done
    wait_for_cluster_healthy 30
    for node in "$NODE1" "$NODE2"; do
        if ! wait_for_service "$node" "lease-sync" 15; then
            warn "lease-sync not running on $node after restore"
        fi
    done

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T27: Standalone lease-sync"
    info "Validates the lease-sync package's init script without ha-cluster"

    local result=0

    setup
    case $? in
        0) ;;
        2) return 0 ;;
        *) cleanup; return 1 ;;
    esac

    test_standalone_starts || result=1
    test_config_protected || result=1
    test_lease_replicated || result=1
    test_handover_on_stop || result=1

    cleanup

    return $result
}

main
exit $?
