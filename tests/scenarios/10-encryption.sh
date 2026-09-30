#!/bin/sh
# 10-encryption.sh - Test T10: Encryption Validation
#
# Validates that AES-256-GCM encryption is active for lease-sync traffic.
# Verifies no plaintext lease data is transmitted over the network, that a
# node with another key rejects synced leases, and that sync resumes once
# the key is restored.
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

# Capture settings
CAPTURE_FILE="/tmp/lease-sync-capture.pcap"
CAPTURE_DURATION=5
LEASE_SYNC_PORT=5378
LEASE_SYNC_CONF="/tmp/ha-cluster/lease-sync.conf"
AUTH_FAILURE="lease-sync\[[0-9]*\]: Received message with invalid authentication tag"

# DHCP client for generating real sync traffic
DHCP_CLIENT_MAC=""
DHCP_LEASE_IP=""

# NODE2 key before the wrong key test, restored by cleanup
ORIG_KEY=""
KEY_CHANGED=false

# Seconds a lease may take to reach the peer, set by setup
SYNC_WINDOW=""

# Node that served the last lease checked by lease_server
LEASE_SERVER=""

# ============================================
# Helper Functions
# ============================================

# Print a node's syslog lines logged at or after an epoch time
# Usage: log_since "node" "$t0"
log_since() {
    exec_node "$1" logread -t 2>/dev/null | \
        awk -v t0="$2" 'match($0, /\[[0-9]+\.[0-9]+\]/) &&
            substr($0, RSTART + 1, RLENGTH - 2) + 0 >= t0'
}

# Print the epoch times of a node's syslog lines matching a pattern
# Usage: log_times "node" "$t0" "pattern"
log_times() {
    log_since "$1" "$2" | grep -e "$3" | sed 's/^[^[]*\[\([0-9.]*\)\].*/\1/'
}

# One-shot request from a client without DHCP state: it broadcasts a
# DISCOVER and takes the first offer, from either node
# Usage: ip=$(request_lease "ha-client1")
request_lease() {
    exec_client "$1" sh -c 'rm -rf /var/lib/dhcpcd/*' 2>/dev/null
    dhcp_request "$1"
}

# Set LEASE_SERVER to the node that served a client's lease: the server
# identifier in the client's lease file, which must also be the only node
# that logged the DHCPACK since t0
# Usage: lease_server "ha-client1" "$ip" "$mac" "$t0"
lease_server() {
    local client="$1" ip="$2" mac="$3" t0="$4"
    local sid node acks=""

    LEASE_SERVER=""
    # Option 54 of the DHCPACK dhcpcd stored (options start at byte 240)
    sid=$(exec_client "$client" od -An -tu1 -v /var/lib/dhcpcd/eth0.lease 2>/dev/null | \
        awk '{for (i = 1; i <= NF; i++) b[n++] = $i}
            END {
                i = 240
                while (i < n && b[i] != 255) {
                    if (b[i] == 0) { i++; continue }
                    if (b[i] == 54 && b[i + 1] == 4) {
                        print b[i + 2] "." b[i + 3] "." b[i + 4] "." b[i + 5]
                        exit
                    }
                    i += 2 + b[i + 1]
                }
            }')
    for node in "$NODE1" "$NODE2"; do
        if log_since "$node" "$t0" | grep -qi "DHCPACK([^)]*) $ip $mac"; then
            acks="$acks $node"
        fi
    done

    case "$sid" in
        "$NODE1_CLIENT_IP") node="$NODE1" ;;
        "$NODE2_CLIENT_IP") node="$NODE2" ;;
        *) node="" ;;
    esac
    if [ -z "$node" ] || [ "$acks" != " $node" ]; then
        fail "Serving node of $ip unclear (server identifier: ${sid:-none}, DHCPACK from:${acks:- none})"
        return 1
    fi
    LEASE_SERVER="$node"
    pass "Lease $ip served by $node (server identifier and DHCPACK)"
}

# Set the NODE2 encryption key as an admin would (UCI, then reload) and
# check that a new lease-sync runs with it: on startup it requests a full
# sync, which NODE1 must accept or reject
# Usage: set_node2_key "$key" accepted|rejected
set_node2_key() {
    local key="$1" expect="$2"
    local old_pid pid t0 stopped log count=0

    old_pid=$(exec_node "$NODE2" pidof lease-sync)
    t0=$(exec_node "$NODE2" date +%s)
    if ! exec_node "$NODE2" uci set ha-cluster.config.encryption_key="$key" ||
       ! exec_node "$NODE2" uci commit ha-cluster ||
       ! exec_node "$NODE2" /etc/init.d/ha-cluster reload; then
        fail "Could not set the encryption key on $NODE2"
        return 1
    fi
    if [ "$(uci_get "$NODE2" ha-cluster.config.encryption_key)" != "$key" ] ||
       ! exec_node "$NODE2" grep -qx "psk_key=$key" "$LEASE_SYNC_CONF"; then
        fail "Encryption key not in the $NODE2 lease-sync config"
        return 1
    fi

    while [ $count -lt 15 ]; do
        pid=$(exec_node "$NODE2" pidof lease-sync)
        if [ -n "$pid" ] && [ "$pid" != "$old_pid" ] &&
           log_since "$NODE2" "$t0" | grep -q "lease-sync\[$pid\]: Reconciliation complete"; then
            break
        fi
        sleep 1
        count=$((count + 1))
    done
    if [ $count -ge 15 ]; then
        fail "lease-sync did not restart on $NODE2 (pid ${old_pid:-none} -> ${pid:-none})"
        return 1
    fi

    # Only the new daemon talks to NODE1 once the old one left its loop
    stopped=$(log_times "$NODE2" "$t0" "lease-sync\[$old_pid\]: Exiting main event loop" | head -1)
    log=$(log_since "$NODE1" "${stopped:-$t0}")
    case "$expect" in
        accepted)
            echo "$log" | grep -q "Received sync request from $NODE2"
            ;;
        rejected)
            echo "$log" | grep -q "$AUTH_FAILURE" &&
                ! echo "$log" | grep -q "Received sync request from $NODE2"
            ;;
    esac || {
        fail "$NODE1 did not see the $NODE2 key as $expect"
        return 1
    }
    pass "$NODE2 lease-sync restarted with a key $NODE1 $expect"
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Test Setup"

    # Check if lease-sync is running
    local lease_sync_running=true
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            lease_sync_running=false
            break
        fi
    done

    if [ "$lease_sync_running" = "false" ]; then
        skip "Encryption validation test" "lease-sync not running on all nodes"
        return 1
    fi

    # Check if tcpdump is available
    # Note: 'command -v' is a shell built-in, must run via sh -c
    if ! exec_node "$NODE2" sh -c 'command -v tcpdump' >/dev/null 2>&1; then
        skip "Encryption validation test" "tcpdump not available"
        return 1
    fi

    # Check if DHCP clients are available (needed for real sync traffic)
    if ! client_running "$CLIENT1" || ! client_running "$CLIENT2"; then
        skip "Encryption validation test" "DHCP client containers not available"
        return 1
    fi

    DHCP_CLIENT_MAC=$(get_client_mac "$CLIENT1")
    if [ -z "$DHCP_CLIENT_MAC" ]; then
        skip "Encryption validation test" "cannot determine client MAC address"
        return 1
    fi

    # A lease reaches the peer by the ADD broadcast on the DHCP event, by
    # the injection retries (3 x 5s) or by the full sync the peer requests
    # every sync_interval: wait past all three
    local interval
    interval=$(exec_node "$NODE2" sed -n 's/^sync_interval=//p' "$LEASE_SYNC_CONF")
    SYNC_WINDOW=$((${interval:-30} + 5))
    [ "$SYNC_WINDOW" -lt 20 ] && SYNC_WINDOW=20

    pass "Test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_encryption_key_configured() {
    subheader "Verify Encryption Key Configured"

    local key_configured=true

    for node in "$NODE1" "$NODE2"; do
        # Check UCI configuration
        local key
        key=$(exec_node "$node" uci get ha-cluster.config.encryption_key 2>/dev/null || echo "")

        if [ -n "$key" ] && [ ${#key} -ge 32 ]; then
            pass "Encryption key configured on $node (length: ${#key})"
        else
            # Check if key is in lease-sync config file
            key=$(exec_node "$node" grep -o 'encryption_key.*' /tmp/lease-sync.conf 2>/dev/null | head -1 || echo "")
            if [ -n "$key" ]; then
                pass "Encryption key found in lease-sync.conf on $node"
            else
                fail "No encryption key configured on $node"
                key_configured=false
            fi
        fi
    done

    [ "$key_configured" = "true" ]
}

test_capture_sync_traffic() {
    subheader "Capture Lease Sync Traffic"

    # Start tcpdump on NODE2 to capture incoming lease-sync traffic.
    # Use a real DHCP client to generate traffic — ubus add_lease does not
    # trigger the hotplug/sync chain (LEASE_NEW flag is cleared by design).
    info "Starting traffic capture on $NODE2 (port $LEASE_SYNC_PORT)..."

    # Kill any leftover tcpdump and remove old capture file
    exec_node "$NODE2" killall tcpdump 2>/dev/null || true
    exec_node "$NODE2" rm -f "$CAPTURE_FILE" 2>/dev/null || true
    sleep 1

    # Start tcpdump in background (stderr to /tmp to avoid suppressing errors)
    exec_node "$NODE2" sh -c "tcpdump -i any udp port $LEASE_SYNC_PORT -w $CAPTURE_FILE -c 50 2>/tmp/tcpdump.err &"
    sleep 1

    # Verify tcpdump is running
    if exec_node "$NODE2" pgrep tcpdump >/dev/null 2>&1; then
        pass "Traffic capture started"
    else
        fail "Failed to start traffic capture"
        return 1
    fi

    # Generate real sync traffic via DHCP client
    info "Requesting DHCP lease to generate sync traffic..."
    local t0
    t0=$(exec_node "$NODE1" date +%s)
    DHCP_LEASE_IP=$(request_lease "$CLIENT1")
    if [ -n "$DHCP_LEASE_IP" ]; then
        pass "DHCP lease obtained: $DHCP_LEASE_IP"
    else
        fail "Failed to obtain DHCP lease for traffic generation"
        exec_node "$NODE2" killall tcpdump 2>/dev/null || true
        return 1
    fi

    # Wait for sync traffic to be captured
    info "Waiting for sync traffic..."
    sleep $CAPTURE_DURATION

    # Stop tcpdump and wait for file flush
    exec_node "$NODE2" killall tcpdump 2>/dev/null || true
    sleep 2
    exec_node "$NODE2" sync 2>/dev/null || true

    # Verify capture file exists and has data
    local capture_size
    capture_size=$(exec_node "$NODE2" sh -c "wc -c < '$CAPTURE_FILE'" 2>/dev/null || echo "0")

    if [ "$capture_size" -gt 100 ]; then
        pass "Captured $capture_size bytes of traffic"
    else
        fail "Capture too small ($capture_size bytes) - no sync traffic observed"
        return 1
    fi

    # Heartbeats alone would fill the capture: it must hold the packet the
    # serving node sent when it broadcast the lease. All messages have the
    # same size, and heartbeats and sync requests may come within a second
    # of the lease: match on time. The broadcast is sent right before its
    # log line, whose timestamp is truncated to the millisecond.
    local src bcast offset=""
    lease_server "$CLIENT1" "$DHCP_LEASE_IP" "$DHCP_CLIENT_MAC" "$t0" || return 1
    src="$NODE1_BACKEND_IP"
    [ "$LEASE_SERVER" = "$NODE2" ] && src="$NODE2_BACKEND_IP"
    bcast=$(log_times "$LEASE_SERVER" "$t0" "lease-sync\[[0-9]*\]: Processed local lease: $DHCP_LEASE_IP " | head -1)
    [ -n "$bcast" ] && offset=$(exec_node "$NODE2" tcpdump -r "$CAPTURE_FILE" -n -tt src host "$src" 2>/dev/null | \
        awk -v b="$bcast" '$1 - b >= -0.05 && $1 - b <= 0.005 {printf "%+.4f", $1 - b; exit}')
    if [ -n "$offset" ]; then
        pass "Capture holds the broadcast of $DHCP_LEASE_IP from $LEASE_SERVER (${offset}s from its log line)"
    else
        fail "Capture lacks the broadcast of $DHCP_LEASE_IP from $LEASE_SERVER"
        return 1
    fi
}

test_no_plaintext_lease_data() {
    subheader "Verify No Plaintext Lease Data in Capture"

    # Check if capture file exists and has sufficient data
    if ! exec_node "$NODE2" test -f "$CAPTURE_FILE" 2>/dev/null; then
        skip "Plaintext check" "No capture file available"
        return 0
    fi

    local capture_size
    capture_size=$(exec_node "$NODE2" sh -c "wc -c < '$CAPTURE_FILE'" 2>/dev/null || echo "0")
    if [ "$capture_size" -le 100 ]; then
        skip "Plaintext check" "Capture too small to analyze ($capture_size bytes)"
        return 0
    fi

    # Search the raw capture for fields a plain message carries as text:
    # the client MAC, the "LSYN" magic and the sender node ID. The lease IP
    # travels in binary either way.
    info "Searching for plaintext patterns in raw capture..."
    info "Checking for MAC=$DHCP_CLIENT_MAC, magic, node IDs"

    local plaintext_found=false pattern

    if [ -n "$DHCP_CLIENT_MAC" ] &&
       exec_node "$NODE2" grep -qi "$DHCP_CLIENT_MAC" "$CAPTURE_FILE" 2>/dev/null; then
        fail "Plaintext MAC address found in capture: $DHCP_CLIENT_MAC"
        plaintext_found=true
    else
        pass "MAC address not found in plaintext"
    fi

    for pattern in LSYN "$NODE1" "$NODE2"; do
        if exec_node "$NODE2" grep -q "$pattern" "$CAPTURE_FILE" 2>/dev/null; then
            fail "Plaintext message field found in capture: $pattern"
            plaintext_found=true
        fi
    done

    if [ "$plaintext_found" = "false" ]; then
        pass "No plaintext data found - encryption appears active"
        return 0
    else
        info "Plaintext data found - encryption may not be working"
        return 1
    fi
}

test_wrong_key_rejected() {
    subheader "Verify Wrong Encryption Key Rejected"

    local wrong_key t0 ip peer bcast result=0

    ORIG_KEY=$(uci_get "$NODE2" ha-cluster.config.encryption_key)
    if [ -z "$ORIG_KEY" ] ||
       [ "$ORIG_KEY" != "$(uci_get "$NODE1" ha-cluster.config.encryption_key)" ]; then
        fail "Nodes do not share an encryption key"
        return 1
    fi

    clear_node_leases || { fail "Could not clear leases"; return 1; }

    # Differs from the original in every hex digit
    wrong_key=$(echo "$ORIG_KEY" | tr '0-9a-f' '1-9a-f0')
    KEY_CHANGED=true
    set_node2_key "$wrong_key" rejected || return 1

    t0=$(exec_node "$NODE1" date +%s)
    ip=$(request_lease "$CLIENT1")
    if [ -z "$ip" ]; then
        fail "$CLIENT1 obtained no lease with mismatched keys"
        return 1
    fi
    lease_server "$CLIENT1" "$ip" "$DHCP_CLIENT_MAC" "$t0" || return 1
    peer=$(get_peer_node "$LEASE_SERVER")

    info "Waiting ${SYNC_WINDOW}s for $ip to reach $peer..."
    sleep "$SYNC_WINDOW"

    if get_all_leases "$peer" | grep -qi "$DHCP_CLIENT_MAC"; then
        fail "Lease synced to $peer despite wrong encryption key"
        result=1
    else
        pass "Lease absent from $peer after ${SYNC_WINDOW}s"
    fi

    # The absence must come from the key: the peer rejected a message
    # when the server broadcast the lease, and decrypted none for it
    bcast=$(log_times "$LEASE_SERVER" "$t0" "lease-sync\[[0-9]*\]: Processed local lease: $ip " | head -1)
    if [ -z "$bcast" ]; then
        fail "$LEASE_SERVER did not broadcast $ip"
        result=1
    elif log_times "$peer" "$t0" "$AUTH_FAILURE" | \
         awk -v b="$bcast" '$1 >= b - 1 && $1 <= b + 2 {f = 1} END {exit !f}'; then
        pass "$peer rejected the lease broadcast (invalid authentication tag)"
    else
        fail "$peer logged no authentication failure for the lease broadcast"
        result=1
    fi
    if log_since "$peer" "$t0" | grep -q "Received [A-Z]* for $ip from"; then
        fail "$peer decrypted a message for $ip"
        result=1
    fi

    return $result
}

test_restored_key_syncs() {
    subheader "Verify Lease Sync After Key Restore"

    local mac node t0 ip peer

    if [ "$KEY_CHANGED" != "true" ]; then
        fail "Encryption key was not changed, nothing to restore"
        return 1
    fi
    info "Restoring original encryption key..."
    set_node2_key "$ORIG_KEY" accepted || return 1
    KEY_CHANGED=false

    # A fresh client: the restarted daemon pulls CLIENT1's lease with its
    # startup sync, so that lease proves nothing about a new broadcast
    mac=$(get_client_mac "$CLIENT2")
    for node in "$NODE1" "$NODE2"; do
        if get_all_leases "$node" | grep -qi "$mac"; then
            fail "$CLIENT2 already holds a lease on $node"
            return 1
        fi
    done

    t0=$(exec_node "$NODE1" date +%s)
    ip=$(request_lease "$CLIENT2")
    if [ -z "$ip" ]; then
        fail "$CLIENT2 obtained no lease with restored keys"
        return 1
    fi
    lease_server "$CLIENT2" "$ip" "$mac" "$t0" || return 1
    peer=$(get_peer_node "$LEASE_SERVER")

    if wait_for_dhcp_lease_by_mac "$peer" "$mac" "$SYNC_WINDOW"; then
        pass "Lease $ip synced to $peer with restored keys"
    else
        fail "Lease $ip did not reach $peer within ${SYNC_WINDOW}s"
        return 1
    fi
    if log_since "$peer" "$t0" | grep -q "Received ADD for $ip from"; then
        pass "$peer decrypted the lease broadcast"
    else
        fail "$peer did not log the ADD for $ip"
        return 1
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    local result=0

    # Remove capture file
    exec_node "$NODE2" rm -f "$CAPTURE_FILE" 2>/dev/null || true

    # Kill any lingering tcpdump
    exec_node "$NODE2" killall tcpdump 2>/dev/null || true

    if [ "$KEY_CHANGED" = "true" ] &&
       { [ "$(uci_get "$NODE2" ha-cluster.config.encryption_key)" != "$ORIG_KEY" ] ||
         ! exec_node "$NODE2" grep -qx "psk_key=$ORIG_KEY" "$LEASE_SYNC_CONF"; }; then
        info "Restoring original encryption key on $NODE2..."
        set_node2_key "$ORIG_KEY" accepted || result=1
    fi
    KEY_CHANGED=false

    # Ensure lease-sync is running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
        fi
    done

    [ "$result" -eq 0 ] && pass "Cleanup complete"
    return $result
}

# ============================================
# Main
# ============================================

main() {
    header "T10: Encryption Validation"
    info "Validates AES-256-GCM encryption is active for lease-sync"

    local result=0

    # Restore the key even when the output reader is gone
    trap 'trap "" PIPE; cleanup; exit 1' INT TERM

    setup || return 0  # Skip if prerequisites not met

    test_encryption_key_configured || result=1
    test_capture_sync_traffic || result=1
    test_no_plaintext_lease_data || result=1
    test_wrong_key_rejected || result=1
    test_restored_key_syncs || result=1

    cleanup || result=1

    return $result
}

main
exit $?
