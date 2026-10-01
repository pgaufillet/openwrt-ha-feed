#!/bin/sh
# 07-startup-reconciliation.sh - Test T07: Startup Reconciliation
#
# Validates that a lease-sync restart keeps the leases dnsmasq holds.
# On startup lease-sync requests a full sync from its peers, injects
# their leases into dnsmasq for about 5s, then only logs how many dnsmasq
# leases no peer reported ("untracked"). Untracked leases stay in dnsmasq
# and reach the peers at their next DHCP event, not at startup: the
# "old" events dnsmasq replays from its lease file during the startup
# window are ignored for them.
#
# Cases:
#   1. A lease only NODE2's dnsmasq holds survives a NODE2 restart, is
#      not announced by its startup replay, and is announced by its next
#      event; the synced lease is kept on both nodes
#   2. NODE2 restarts while NODE1's lease-sync is down
#   3. The encryption key is changed node by node, so each restarted
#      daemon is rejected by its peer, then restored
#   4. Both daemons restart together
#   5. A peer lease replaces an untracked local lease for the same
#      address held by another MAC
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

LEASE_SYNC_CONF="/tmp/ha-cluster/lease-sync.conf"
HOTPLUG_SCRIPT="/etc/hotplug.d/dhcp/50-lease-sync"
AUTH_FAILURE="lease-sync\[[0-9]*\]: Received message with invalid authentication tag"

# Lease written to NODE2's lease file only, unknown to NODE1
UNKNOWN_LEASE_IP="192.168.50.200"
UNKNOWN_LEASE_MAC="aa:bb:cc:dd:ee:01"
UNKNOWN_LEASE_EXPIRY=""

# MAC NODE2's dnsmasq holds for CLIENT2's address in case 5
CONFLICT_MAC="aa:bb:cc:dd:ee:02"

# CLIENT1 lease shared by cases 1-4, served by NODE1 and synced
REAL_LEASE_IP=""
REAL_LEASE_MAC=""

# Original key, restored by cleanup when KEY_CHANGED
ORIG_KEY=""
KEY_CHANGED=false

# Seconds before a peer's periodic sync request, set by setup
SYNC_WINDOW=""

# Last startup completion line found by wait_startup_complete
STARTUP_COMPLETE=""

# ============================================
# Helper Functions
# ============================================

# MAC dnsmasq holds for an address (empty when none)
# Usage: mac=$(lease_mac "node" "192.168.50.100")
lease_mac() {
    exec_node "$1" sh -c "ubus call dnsmasq get_leases | \
        jsonfilter -e '@.leases[@.ip=\"$2\"].mac'" 2>/dev/null
}

# Usage: has_lease "node" "$ip" "$mac"
has_lease() {
    [ "$(lease_mac "$1" "$2")" = "$3" ]
}

# Usage: wait_for_lease_mac "node" "$ip" "$mac" timeout
wait_for_lease_mac() {
    wait_for "lease $2 for $3 on $1" "$4" "has_lease $1 $2 $3"
}

# Start a dhcpcd daemon that only accepts the given server, from a clean
# state; prints the address obtained
# Usage: ip=$(request_lease "ha-client1" "192.168.50.10")
request_lease() {
    exec_client "$1" sh -c 'killall -9 dhcpcd; ip addr flush dev eth0; rm -rf /var/lib/dhcpcd/*' >/dev/null 2>&1
    exec_client "$1" dhcpcd -4 -t 20 --whitelist "$2" eth0 >/dev/null 2>&1
    get_client_ip "$1"
}

# Release the client's lease and stop its dhcpcd daemon
# Usage: release_lease "ha-client1"
release_lease() {
    exec_client "$1" dhcpcd -4 -k eth0 >/dev/null 2>&1
    exec_client "$1" sh -c 'killall -9 dhcpcd; ip addr flush dev eth0' >/dev/null 2>&1
}

# Run the lease-sync hotplug handler as dnsmasq's dhcp-script does.
# Simulates the lease file replay: dnsmasq replays it while lease-sync
# is stopped, so the test sends the "old" event itself
# Usage: lease_event "node" update|add|remove "$ip" "$mac" "$expiry"
lease_event() {
    exec_node "$1" env ACTION="$2" IPADDR="$3" MACADDR="$4" \
        DNSMASQ_LEASE_EXPIRES="$5" sh "$HOTPLUG_SCRIPT" 2>/dev/null
}

# Make sure CLIENT1 holds a lease from NODE1 known to both nodes
ensure_real_lease() {
    if [ -n "$REAL_LEASE_IP" ] &&
       has_lease "$NODE1" "$REAL_LEASE_IP" "$REAL_LEASE_MAC" &&
       has_lease "$NODE2" "$REAL_LEASE_IP" "$REAL_LEASE_MAC"; then
        return 0
    fi

    REAL_LEASE_IP=$(request_lease "$CLIENT1" "$NODE1_CLIENT_IP")
    if [ -z "$REAL_LEASE_IP" ]; then
        fail "$CLIENT1 obtained no lease from $NODE1"
        return 1
    fi
    if ! wait_for_lease_mac "$NODE1" "$REAL_LEASE_IP" "$REAL_LEASE_MAC" 10 ||
       ! wait_for_lease_mac "$NODE2" "$REAL_LEASE_IP" "$REAL_LEASE_MAC" "$SYNC_TIMEOUT"; then
        fail "Lease $REAL_LEASE_IP not on both nodes"
        return 1
    fi
    pass "$CLIENT1 lease $REAL_LEASE_IP served by $NODE1, synced to $NODE2"
}

# Check that the real lease is still on the given nodes
# Usage: check_real_lease "context" "node" ["node"]
check_real_lease() {
    local context="$1" node result=0
    shift
    for node in "$@"; do
        if has_lease "$node" "$REAL_LEASE_IP" "$REAL_LEASE_MAC"; then
            pass "Lease $REAL_LEASE_IP kept on $node $context"
        else
            fail "Lease $REAL_LEASE_IP lost on $node $context"
            result=1
        fi
    done
    return $result
}

# Start lease-sync on the given nodes at the same time, from a stopped
# instance or by procd on a config change
# Usage: start_lease_sync "node" ["node"]
start_lease_sync() {
    local node
    for node in "$@"; do
        exec_node "$node" /etc/init.d/ha-cluster reload >/dev/null 2>&1 &
    done
    wait
}

# Wait for a node's lease-sync, started at or after t0, to log its
# startup completion; sets STARTUP_COMPLETE to that line
# Usage: wait_startup_complete "node" "$t0"
wait_startup_complete() {
    local node="$1" t0="$2" pid count=0

    STARTUP_COMPLETE=""
    while [ $count -lt 20 ]; do
        pid=$(exec_node "$node" pidof lease-sync)
        if [ -n "$pid" ]; then
            STARTUP_COMPLETE=$(log_since "$node" "$t0" | \
                grep "lease-sync\[$pid\]: Startup complete" | tail -1)
            [ -n "$STARTUP_COMPLETE" ] && break
        fi
        sleep 1
        count=$((count + 1))
    done
    if [ -z "$STARTUP_COMPLETE" ]; then
        fail "lease-sync on $node did not log its startup completion"
        return 1
    fi
    pass "lease-sync restarted on $node: ${STARTUP_COMPLETE##*: }"
}

# Wait for a node's lease-sync, started at or after t0, to subscribe to
# the lease events; its startup window then runs for about 5s
# Usage: wait_subscribed "node" "$t0"
wait_subscribed() {
    local node="$1" t0="$2" pid count=0
    while [ $count -lt 50 ]; do
        pid=$(exec_node "$node" pidof lease-sync)
        if [ -n "$pid" ] && log_since "$node" "$t0" | \
           grep -q "lease-sync\[$pid\]: Entering main event loop"; then
            return 0
        fi
        sleep 0.2
        count=$((count + 1))
    done
    fail "lease-sync on $node did not start"
    return 1
}

# Number of untracked leases in STARTUP_COMPLETE (empty when not reported)
untracked_count() {
    echo "$STARTUP_COMPLETE" | sed -n 's/.* \([0-9][0-9]*\) untracked$/\1/p'
}

# lease-sync numbers its messages from 0 at each start, and a peer drops
# (node, sequence) pairs it saw in the last 60s: start a daemon whose
# messages a check needs at least 61s after the previous one stopped
# Usage: wait_after_stop "$stopped"
wait_after_stop() {
    local left=$(($1 + 61 - $(date +%s)))
    if [ "$left" -gt 0 ]; then
        info "Waiting ${left}s for the peer to forget the stopped daemon..."
        sleep "$left"
    fi
}

# Restart lease-sync on the given nodes together: stop all, start all
# Usage: restart_lease_sync "node" ["node"]
restart_lease_sync() {
    local node t0
    t0=$(exec_node "$NODE1" date +%s)
    for node in "$@"; do
        if ! service_stop "$node" lease-sync; then
            fail "lease-sync did not stop on $node"
            return 1
        fi
    done
    start_lease_sync "$@"
    for node in "$@"; do
        wait_startup_complete "$node" "$t0" || return 1
    done
}

# Set a node's encryption key as an admin would (UCI, then reload) and
# check that a new lease-sync runs with it: its startup sync request
# must be accepted or rejected by the peer
# Usage: set_key "node" "$key" accepted|rejected
set_key() {
    local node="$1" key="$2" expect="$3"
    local peer old_pid pid t0 stopped log

    peer=$(get_peer_node "$node")
    old_pid=$(exec_node "$node" pidof lease-sync)
    t0=$(exec_node "$node" date +%s)
    if ! exec_node "$node" uci set ha-cluster.config.encryption_key="$key" ||
       ! exec_node "$node" uci commit ha-cluster ||
       ! exec_node "$node" /etc/init.d/ha-cluster reload >/dev/null 2>&1; then
        fail "Could not set the encryption key on $node"
        return 1
    fi
    if ! exec_node "$node" grep -qx "psk_key=$key" "$LEASE_SYNC_CONF"; then
        fail "Encryption key not in the $node lease-sync config"
        return 1
    fi

    wait_startup_complete "$node" "$t0" || return 1
    pid=$(exec_node "$node" pidof lease-sync)
    if [ "$pid" = "$old_pid" ]; then
        fail "lease-sync did not restart on $node (pid $pid)"
        return 1
    fi

    # Only the new daemon talks to the peer once the old one left its loop
    stopped=$(log_since "$node" "$t0" | \
        grep "lease-sync\[$old_pid\]: Exiting main event loop" | \
        sed 's/^[^[]*\[\([0-9.]*\)\].*/\1/' | head -1)
    log=$(log_since "$peer" "${stopped:-$t0}")
    case "$expect" in
        accepted)
            echo "$log" | grep -q "Received sync request from $node"
            ;;
        rejected)
            echo "$log" | grep -q "$AUTH_FAILURE" &&
                ! echo "$log" | grep -q "Received sync request from $node"
            ;;
    esac || {
        fail "$peer did not see the $node key as $expect"
        return 1
    }
    pass "$node lease-sync restarted with a key $peer $expect"
}

# Wait until a node's lease-sync answers a periodic sync request from
# its peer after t0: whatever it holds has then been offered to the peer
# Usage: wait_sync_response "node" "$t0"
wait_sync_response() {
    local node="$1" t0="$2" peer_ip pid
    case "$(get_peer_node "$node")" in
        "$NODE1") peer_ip="$NODE1_BACKEND_IP" ;;
        *) peer_ip="$NODE2_BACKEND_IP" ;;
    esac
    pid=$(exec_node "$node" pidof lease-sync)
    wait_for "sync response from $node" "$SYNC_WINDOW" \
        "log_since $node $t0 | grep -q 'lease-sync\[$pid\]: Sent [0-9]* leases to $peer_ip in sync response'"
}

# Stop NODE2's lease-sync and dnsmasq, apply a lease file edit, start
# dnsmasq again. lease-sync stays stopped; LEASE_SYNC_STOPPED records when
# Usage: edit_node2_leases "sed script" "line to append"
LEASE_SYNC_STOPPED=""
edit_node2_leases() {
    if ! service_stop "$NODE2" lease-sync; then
        fail "lease-sync did not stop on $NODE2"
        return 1
    fi
    LEASE_SYNC_STOPPED=$(date +%s)
    exec_node "$NODE2" /etc/init.d/dnsmasq stop >/dev/null 2>&1
    if ! wait_for_service_stopped "$NODE2" dnsmasq 10; then
        fail "dnsmasq did not stop on $NODE2"
        return 1
    fi
    # dnsmasq owns the file while running: edit it only now
    [ -n "$1" ] && exec_node "$NODE2" sed -i "$1" /tmp/dhcp.leases
    exec_node "$NODE2" sh -c "echo '$2' >> /tmp/dhcp.leases"
    exec_node "$NODE2" /etc/init.d/dnsmasq start >/dev/null 2>&1
    if ! wait_for "dnsmasq ubus on $NODE2" 15 \
            "exec_node $NODE2 ubus list dnsmasq"; then
        fail "dnsmasq did not start on $NODE2"
        return 1
    fi
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    local node interval

    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            skip "Startup reconciliation test" "lease-sync not running on $node"
            return 1
        fi
    done

    if ! client_running "$CLIENT1" || ! client_running "$CLIENT2"; then
        skip "Startup reconciliation test" "DHCP client containers not available"
        return 1
    fi

    REAL_LEASE_MAC=$(get_client_mac "$CLIENT1")
    if [ -z "$REAL_LEASE_MAC" ]; then
        skip "Startup reconciliation test" "cannot determine client MAC address"
        return 1
    fi

    ORIG_KEY=$(uci_get "$NODE1" ha-cluster.config.encryption_key)
    if [ -z "$ORIG_KEY" ] ||
       [ "$ORIG_KEY" != "$(uci_get "$NODE2" ha-cluster.config.encryption_key)" ]; then
        fail "Nodes do not share an encryption key"
        return 1
    fi

    interval=$(exec_node "$NODE2" sed -n 's/^sync_interval=//p' "$LEASE_SYNC_CONF")
    SYNC_WINDOW=$((${interval:-30} + 5))

    for node in "$NODE1" "$NODE2"; do
        delete_lease "$node" "$UNKNOWN_LEASE_IP" >/dev/null 2>&1 || true
    done

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

# Case 1: a lease only NODE2 holds is kept and not announced at startup
test_unknown_lease_kept() {
    subheader "Case 1: Unknown Local Lease Kept"

    local t0 pid n result=0

    ensure_real_lease || return 1
    if [ -n "$(lease_mac "$NODE1" "$UNKNOWN_LEASE_IP")" ]; then
        fail "$UNKNOWN_LEASE_IP already on $NODE1"
        return 1
    fi

    UNKNOWN_LEASE_EXPIRY=$(( $(exec_node "$NODE2" date +%s) + 7200 ))
    edit_node2_leases "" \
        "$UNKNOWN_LEASE_EXPIRY $UNKNOWN_LEASE_MAC $UNKNOWN_LEASE_IP unknown-host *" || return 1
    if ! wait_for_lease_mac "$NODE2" "$UNKNOWN_LEASE_IP" "$UNKNOWN_LEASE_MAC" 15; then
        fail "dnsmasq on $NODE2 did not load $UNKNOWN_LEASE_IP"
        return 1
    fi
    pass "$UNKNOWN_LEASE_IP loaded by dnsmasq on $NODE2 only"

    # NODE1 must receive the restarted daemon's later lease event
    wait_after_stop "$LEASE_SYNC_STOPPED"

    # Replay the lease as dnsmasq does when it loads its lease file, while
    # the new daemon is still waiting for its peers. dnsmasq's own replay
    # went nowhere (lease-sync stopped): keep it out of the log window.
    sleep 2
    t0=$(exec_node "$NODE1" date +%s)
    start_lease_sync "$NODE2"
    wait_subscribed "$NODE2" "$t0" || return 1
    lease_event "$NODE2" update "$UNKNOWN_LEASE_IP" "$UNKNOWN_LEASE_MAC" \
        "$UNKNOWN_LEASE_EXPIRY"
    wait_startup_complete "$NODE2" "$t0" || return 1
    pid=$(exec_node "$NODE2" pidof lease-sync)
    if log_since "$NODE2" "$t0" | \
       grep -e "update event for $UNKNOWN_LEASE_IP published" \
            -e "lease-sync\[$pid\]: Startup complete" | \
       head -1 | grep -q "update event"; then
        pass "Lease file replay sent during the startup window"
    else
        fail "Lease file replay not sent before the startup completion"
        result=1
    fi

    n=$(untracked_count)
    if [ "${n:-0}" -ge 1 ]; then
        pass "Startup completion reports $n untracked lease(s)"
    else
        fail "Startup completion reports no untracked lease: $STARTUP_COMPLETE"
        result=1
    fi

    # NODE2 then answers a periodic sync request: it offers only what
    # it tracks
    if ! wait_sync_response "$NODE2" "$t0"; then
        fail "$NODE2 answered no sync request within ${SYNC_WINDOW}s"
        result=1
    fi
    if has_lease "$NODE2" "$UNKNOWN_LEASE_IP" "$UNKNOWN_LEASE_MAC"; then
        pass "$UNKNOWN_LEASE_IP kept on $NODE2"
    else
        fail "$UNKNOWN_LEASE_IP deleted from $NODE2"
        result=1
    fi
    if [ -z "$(lease_mac "$NODE1" "$UNKNOWN_LEASE_IP")" ] &&
       ! log_since "$NODE1" "$t0" | grep -q "Received [A-Z]* for $UNKNOWN_LEASE_IP from"; then
        pass "$UNKNOWN_LEASE_IP not announced to $NODE1"
    else
        fail "$UNKNOWN_LEASE_IP announced to $NODE1 at startup"
        result=1
    fi
    check_real_lease "after the $NODE2 restart" "$NODE1" "$NODE2" || result=1

    # The next event of the untracked lease announces it
    lease_event "$NODE2" update "$UNKNOWN_LEASE_IP" "$UNKNOWN_LEASE_MAC" \
        "$UNKNOWN_LEASE_EXPIRY"
    if wait_for_lease_mac "$NODE1" "$UNKNOWN_LEASE_IP" "$UNKNOWN_LEASE_MAC" 10; then
        pass "$UNKNOWN_LEASE_IP announced to $NODE1 by its next event"
    else
        fail "$UNKNOWN_LEASE_IP not announced to $NODE1 by its next event"
        result=1
    fi

    delete_lease "$NODE2" "$UNKNOWN_LEASE_IP" >/dev/null 2>&1
    wait_for_ubus_lease_absent "$NODE1" "$UNKNOWN_LEASE_IP" 10 || true
    return $result
}

# Case 2: a restart while the peer is down keeps the leases
test_peer_down() {
    subheader "Case 2: Restart While Peer Down"

    local n result=0

    ensure_real_lease || return 1
    if ! service_stop "$NODE1" lease-sync; then
        fail "lease-sync did not stop on $NODE1"
        return 1
    fi
    pass "lease-sync stopped on $NODE1"

    restart_lease_sync "$NODE2" || return 1
    n=$(untracked_count)
    if [ "${n:-0}" -ge 1 ]; then
        pass "No peer reported the lease to $NODE2 ($n untracked)"
    else
        fail "Startup completion on $NODE2 reports no untracked lease: $STARTUP_COMPLETE"
        result=1
    fi
    check_real_lease "after the startup window" "$NODE2" || result=1

    restart_lease_sync "$NODE1" || return 1
    check_real_lease "after both restarts" "$NODE1" "$NODE2" || result=1
    return $result
}

# Case 3: a key changed node by node keeps the leases
test_key_change() {
    subheader "Case 3: Key Change Node by Node"

    local new_key mac ip result=0

    ensure_real_lease || return 1

    # Differs from the original in every hex digit
    new_key=$(echo "$ORIG_KEY" | tr '0-9a-f' '1-9a-f0')
    KEY_CHANGED=true

    set_key "$NODE2" "$new_key" rejected || return 1
    check_real_lease "with mismatched keys" "$NODE2" || result=1

    set_key "$NODE1" "$new_key" accepted || return 1
    check_real_lease "with the new key on both" "$NODE1" "$NODE2" || result=1

    info "Restoring the original key..."
    set_key "$NODE2" "$ORIG_KEY" rejected || return 1
    set_key "$NODE1" "$ORIG_KEY" accepted || return 1
    KEY_CHANGED=false
    check_real_lease "with the original key restored" "$NODE1" "$NODE2" || result=1

    # A new lease proves the restored keys sync again
    mac=$(get_client_mac "$CLIENT2")
    ip=$(request_lease "$CLIENT2" "$NODE1_CLIENT_IP")
    if [ -z "$ip" ]; then
        fail "$CLIENT2 obtained no lease from $NODE1"
        return 1
    fi
    if wait_for_lease_mac "$NODE2" "$ip" "$mac" "$SYNC_TIMEOUT"; then
        pass "New lease $ip synced to $NODE2 with the restored key"
    else
        fail "New lease $ip did not reach $NODE2 with the restored key"
        result=1
    fi
    release_lease "$CLIENT2"
    wait_for_ubus_lease_absent "$NODE2" "$ip" 10 || true
    return $result
}

# Case 4: both daemons restarted together keep the leases
test_both_restart() {
    subheader "Case 4: Both Nodes Restart Together"

    local node t0 n result=0

    ensure_real_lease || return 1
    t0=$(exec_node "$NODE1" date +%s)
    for node in "$NODE1" "$NODE2"; do
        if ! service_stop "$node" lease-sync; then
            fail "lease-sync did not stop on $node"
            return 1
        fi
    done
    pass "lease-sync stopped on both nodes"

    start_lease_sync "$NODE1" "$NODE2"
    # Neither daemon tracked the lease when the other one answered
    for node in "$NODE1" "$NODE2"; do
        wait_startup_complete "$node" "$t0" || return 1
        n=$(untracked_count)
        if [ "${n:-0}" -ge 1 ]; then
            pass "No peer reported the lease to $node ($n untracked)"
        else
            fail "Startup completion on $node reports no untracked lease: $STARTUP_COMPLETE"
            result=1
        fi
    done
    check_real_lease "after the joint restart" "$NODE1" "$NODE2" || result=1
    return $result
}

# Case 5: a peer lease replaces a contradicting untracked local one
test_contradicted_lease() {
    subheader "Case 5: Peer Lease Replaces Untracked Local Lease"

    local mac ip t0 expiry result=0

    mac=$(get_client_mac "$CLIENT2")
    t0=$(exec_node "$NODE1" date +%s)
    ip=$(request_lease "$CLIENT2" "$NODE1_CLIENT_IP")
    if [ -z "$ip" ]; then
        fail "$CLIENT2 obtained no lease from $NODE1"
        return 1
    fi
    if ! wait_for_lease_mac "$NODE2" "$ip" "$mac" "$SYNC_TIMEOUT" ||
       ! log_since "$NODE1" "$t0" | grep -q "Processed local lease: $ip "; then
        fail "Lease $ip not served by $NODE1 and synced to $NODE2"
        return 1
    fi
    pass "$CLIENT2 lease $ip tracked by $NODE1, synced to $NODE2"

    # NODE2's dnsmasq now gives the address to another MAC
    expiry=$(( $(exec_node "$NODE2" date +%s) + 7200 ))
    edit_node2_leases "/ $ip /d" "$expiry $CONFLICT_MAC $ip * *" || return 1
    if ! wait_for_lease_mac "$NODE2" "$ip" "$CONFLICT_MAC" 15; then
        fail "dnsmasq on $NODE2 did not load $ip for $CONFLICT_MAC"
        return 1
    fi
    pass "$NODE2 holds $ip for $CONFLICT_MAC, $NODE1 for $mac"

    # NODE1 must receive the restarted daemon's startup sync request
    wait_after_stop "$LEASE_SYNC_STOPPED"
    t0=$(exec_node "$NODE1" date +%s)
    start_lease_sync "$NODE2"
    wait_startup_complete "$NODE2" "$t0" || return 1
    if log_since "$NODE1" "$t0" | grep -q "Received sync request from $NODE2"; then
        pass "$NODE1 answered the $NODE2 startup sync request"
    else
        fail "$NODE1 ignored the $NODE2 startup sync request"
        result=1
    fi
    if has_lease "$NODE2" "$ip" "$mac"; then
        pass "$NODE2 holds $ip for $mac after its restart"
    else
        fail "$NODE2 holds $ip for '$(lease_mac "$NODE2" "$ip")', expected $mac"
        result=1
    fi
    if has_lease "$NODE1" "$ip" "$mac"; then
        pass "$NODE1 still holds $ip for $mac"
    else
        fail "$NODE1 holds $ip for '$(lease_mac "$NODE1" "$ip")', expected $mac"
        result=1
    fi

    release_lease "$CLIENT2"
    wait_for_ubus_lease_absent "$NODE2" "$ip" 10 || true
    return $result
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    local node result=0

    if [ "$KEY_CHANGED" = "true" ]; then
        info "Restoring the original encryption key..."
        for node in "$NODE1" "$NODE2"; do
            exec_node "$node" uci set ha-cluster.config.encryption_key="$ORIG_KEY"
            exec_node "$node" uci commit ha-cluster
        done
        KEY_CHANGED=false
    fi

    # Bring back whatever a failed case left stopped
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" dnsmasq; then
            exec_node "$node" /etc/init.d/dnsmasq start >/dev/null 2>&1 || true
        fi
    done
    start_lease_sync "$NODE1" "$NODE2"
    for node in "$NODE1" "$NODE2"; do
        if ! wait_for_service "$node" lease-sync 15 ||
           ! exec_node "$node" grep -qx "psk_key=$ORIG_KEY" "$LEASE_SYNC_CONF"; then
            fail "lease-sync not restored on $node"
            result=1
        fi
    done

    for node in "$CLIENT1" "$CLIENT2"; do
        release_lease "$node"
    done
    sleep 2
    for node in "$NODE1" "$NODE2"; do
        delete_lease "$node" "$UNKNOWN_LEASE_IP" >/dev/null 2>&1 || true
        [ -n "$REAL_LEASE_IP" ] &&
            delete_lease "$node" "$REAL_LEASE_IP" >/dev/null 2>&1 || true
    done

    [ "$result" -eq 0 ] && pass "Cleanup complete"
    return $result
}

# ============================================
# Main
# ============================================

main() {
    header "T07: Startup Reconciliation"
    info "Validates a lease-sync restart keeps the leases dnsmasq holds"

    local result=0

    # Restore the key even when the output reader is gone
    trap 'trap "" PIPE; cleanup; exit 1' INT TERM

    setup || return 0  # Skip if prerequisites not met

    test_unknown_lease_kept || result=1
    test_peer_down || result=1
    test_key_change || result=1
    test_both_restart || result=1
    test_contradicted_lease || result=1

    cleanup || result=1

    return $result
}

main
exit $?
