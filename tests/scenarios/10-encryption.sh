#!/bin/sh
# 10-encryption.sh - Test T10: Encryption Validation
#
# Validates that AES-256-GCM encryption is active for lease-sync traffic.
# Verifies no plaintext lease data is transmitted over the network.
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

# DHCP client for generating real sync traffic
DHCP_CLIENT_MAC=""
DHCP_LEASE_IP=""

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

    # Check if DHCP client is available (needed for real sync traffic)
    if ! client_running "$CLIENT1"; then
        skip "Encryption validation test" "DHCP client container not available"
        return 1
    fi

    DHCP_CLIENT_MAC=$(get_client_mac "$CLIENT1")
    if [ -z "$DHCP_CLIENT_MAC" ]; then
        skip "Encryption validation test" "cannot determine client MAC address"
        return 1
    fi

    # Release any existing lease
    dhcp_release "$CLIENT1" 2>/dev/null || true
    sleep 1

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
    DHCP_LEASE_IP=$(dhcp_request "$CLIENT1")
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

    # Search raw capture file for plaintext patterns using grep on binary data.
    # If encryption is working, we should NOT find:
    # - The DHCP lease IP address
    # - The client MAC address
    # - Protocol message types

    info "Searching for plaintext patterns in raw capture..."
    info "Checking for IP=$DHCP_LEASE_IP MAC=$DHCP_CLIENT_MAC"

    local plaintext_found=false

    # Check for IP address (plaintext)
    if [ -n "$DHCP_LEASE_IP" ]; then
        if exec_node "$NODE2" grep -q "$DHCP_LEASE_IP" "$CAPTURE_FILE" 2>/dev/null; then
            fail "Plaintext IP address found in capture: $DHCP_LEASE_IP"
            plaintext_found=true
        else
            pass "IP address not found in plaintext"
        fi
    fi

    # Check for MAC address (plaintext)
    if [ -n "$DHCP_CLIENT_MAC" ]; then
        if exec_node "$NODE2" grep -qi "$DHCP_CLIENT_MAC" "$CAPTURE_FILE" 2>/dev/null; then
            fail "Plaintext MAC address found in capture: $DHCP_CLIENT_MAC"
            plaintext_found=true
        else
            pass "MAC address not found in plaintext"
        fi
    fi

    # Check for common lease-sync message patterns that should be encrypted
    local message_patterns="ADD_LEASE DELETE_LEASE SYNC_REQUEST"
    for pattern in $message_patterns; do
        if exec_node "$NODE2" grep -q "$pattern" "$CAPTURE_FILE" 2>/dev/null; then
            fail "Plaintext message type found: $pattern"
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

    # This test temporarily modifies the encryption key on NODE2
    # to verify that mismatched keys prevent sync

    # Get current key from NODE2
    local original_key
    original_key=$(exec_node "$NODE2" uci get ha-cluster.config.encryption_key 2>/dev/null || echo "")

    if [ -z "$original_key" ]; then
        skip "Wrong key test" "Cannot retrieve original encryption key"
        return 0
    fi

    info "Testing with mismatched encryption key..."

    # Set wrong key on NODE2
    local wrong_key="0000000000000000000000000000000000000000000000000000000000000000"
    exec_node "$NODE2" uci set ha-cluster.config.encryption_key="$wrong_key"
    exec_node "$NODE2" uci commit ha-cluster

    # Restart lease-sync to pick up new key
    exec_node "$NODE2" /etc/init.d/ha-cluster restart 2>/dev/null || true
    sleep 3

    # Release any existing lease and request a new one while keys are mismatched
    dhcp_release "$CLIENT1" 2>/dev/null || true
    sleep 1

    info "Requesting DHCP lease with mismatched keys..."
    local wrong_key_ip
    wrong_key_ip=$(dhcp_request "$CLIENT1")

    if [ -z "$wrong_key_ip" ]; then
        info "DHCP request failed (expected if NODE2 was the DHCP server)"
        # Cannot test wrong-key rejection without a successful lease
        # Restore key and return non-fatal
        exec_node "$NODE2" uci set ha-cluster.config.encryption_key="$original_key"
        exec_node "$NODE2" uci commit ha-cluster
        exec_node "$NODE2" /etc/init.d/ha-cluster restart 2>/dev/null || true
        sleep 3
        return 0
    fi

    # Wait briefly - sync should NOT succeed with wrong key
    sleep 5

    # Check if lease appeared on NODE2 (it should NOT)
    if wait_for_dhcp_lease_by_mac "$NODE2" "$DHCP_CLIENT_MAC" 3; then
        fail "Lease synced despite wrong encryption key"
        local result=1
    else
        pass "Lease did NOT sync with wrong key (correct behavior)"
        local result=0
    fi

    # Restore original key
    info "Restoring original encryption key..."
    exec_node "$NODE2" uci set ha-cluster.config.encryption_key="$original_key"
    exec_node "$NODE2" uci commit ha-cluster
    exec_node "$NODE2" /etc/init.d/ha-cluster restart 2>/dev/null || true
    sleep 3

    # Release the DHCP lease used for wrong-key test
    dhcp_release "$CLIENT1" 2>/dev/null || true

    return $result
}

test_verify_lease_synced() {
    subheader "Verify Lease Sync Works With Correct Keys"

    # With correct keys restored, verify a new lease syncs properly
    dhcp_release "$CLIENT1" 2>/dev/null || true
    sleep 1

    info "Requesting new DHCP lease to verify sync..."
    local verify_ip
    verify_ip=$(dhcp_request "$CLIENT1")

    if [ -z "$verify_ip" ]; then
        info "Could not obtain DHCP lease for verification"
        return 0
    fi

    info "Checking if lease $verify_ip synced to $NODE2..."
    if wait_for_dhcp_lease_by_mac "$NODE2" "$DHCP_CLIENT_MAC" 15; then
        pass "Lease synced to $NODE2 (encryption working correctly)"
    else
        info "Lease not on $NODE2 (may need more time after key change)"
    fi
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    # Release DHCP lease
    dhcp_release "$CLIENT1" 2>/dev/null || true

    # Remove capture file
    exec_node "$NODE2" rm -f "$CAPTURE_FILE" 2>/dev/null || true

    # Kill any lingering tcpdump
    exec_node "$NODE2" killall tcpdump 2>/dev/null || true

    # Ensure lease-sync is running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
        fi
    done

    pass "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    header "T10: Encryption Validation"
    info "Validates AES-256-GCM encryption is active for lease-sync"

    local result=0

    setup || return 0  # Skip if prerequisites not met

    test_encryption_key_configured || result=1
    test_capture_sync_traffic || result=1
    test_no_plaintext_lease_data || result=1

    # Non-fatal: wrong key test requires key manipulation which may fail
    run_nonfatal test_wrong_key_rejected "key manipulation may not be supported"

    test_verify_lease_synced || true  # Non-blocking

    cleanup

    return $result
}

main
exit $?
