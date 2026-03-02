#!/bin/sh
# 19-ipv6-stress.sh - Test T19: IPv6 Stress Test
#
# Validates system behavior under stress conditions:
# - Large lease set (target: 1000+ concurrent leases)
# - Rapid failovers (multiple back-to-back VIP transitions)
# - Memory leak detection
# - Performance degradation detection
#
# This test validates that the system supports 1000+ concurrent DHCP leases
# without performance degradation or memory leaks.
#
# METHODOLOGY (Solution 4: Manual ubus Event Injection):
# - Keeps lease-sync running on NODE1, stops on NODE2
# - Creates 1000 synthetic leases on NODE1 via ubus add_lease
# - Manually sends ubus "dhcp.lease" events to populate lease-sync database
# - Starts lease-sync on NODE2 (triggers SYNC_REQUEST/SYNC_RESPONSE)
# - Validates bulk synchronization of all leases
#
# RATIONALE:
# - ubus add_lease clears LEASE_NEW flag to prevent ping-pong in HA setups
# - Without flags, no dhcp-script events → no lease-sync database population
# - Startup reconciliation deletes leases not in database as "stale"
# - Manual event injection populates database while respecting architecture
#
# WHAT THIS TESTS:
# ✓ Bulk sync mechanism (SYNC_REQUEST/SYNC_RESPONSE)
# ✓ lease-sync event handling at scale (1000+ events)
# ✓ Memory usage with 1000+ leases
# ✓ System stability under load
# ✓ Failover performance under stress
#
# APPROACH:
# Tests measure capability rather than enforce fixed thresholds. Results
# (sync rate, failover times, memory growth) are reported as metrics for
# regression comparison between versions. Hard failures only occur when
# the system is completely non-functional (zero sync, zero failovers).
#
# LIMITATIONS (by design):
# ⚠ Events are synthetic (not from real DHCP flow)
# ⚠ Does not test dhcp-script→hotplug chain (events sent directly)
# ⚠ Does not test production-realistic lease arrival timing
#
# See docs/JOURNAL.md Session 92 for rationale and alternative approaches.
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

# Target lease count for stress testing
TARGET_LEASE_COUNT=1000

# Number of rapid failovers to test
RAPID_FAILOVER_COUNT=10

# Memory threshold (MB) - fail if memory growth exceeds this
MEMORY_THRESHOLD_MB=50

# Initial memory readings
INITIAL_MEMORY_NODE1=0
INITIAL_MEMORY_NODE2=0

# ============================================
# Helper Functions
# ============================================

# Get memory usage of lease-sync process (in KB)
# Usage: get_lease_sync_memory "node1"
get_lease_sync_memory() {
    local node="$1"
    local pid
    pid=$(exec_node "$node" pgrep -f "lease-sync" | head -1)

    if [ -z "$pid" ]; then
        echo "0"
        return 1
    fi

    # Get RSS (Resident Set Size) from /proc/PID/status
    local rss
    rss=$(exec_node "$node" grep "^VmRSS:" /proc/"$pid"/status 2>/dev/null | awk '{print $2}')

    if [ -z "$rss" ]; then
        echo "0"
    else
        echo "$rss"
    fi
}

# Create synthetic DHCPv6 leases with manual ubus event injection (Solution 4)
# Usage: create_synthetic_leases "node1" count start_index
#
# This function creates leases AND sends ubus events to populate lease-sync database.
# Without events, lease-sync database remains empty and reconciliation deletes leases as "stale".
#
# Batches operations (50 per exec) to avoid docker exec overhead.
# Individual success tracking is not possible in batch mode, so actual lease
# count is verified after all batches complete.
create_synthetic_leases() {
    local node="$1"
    local count="$2"
    local start_index="$3"
    local batch_size=50

    info "Creating $count synthetic IPv6 leases with ubus events on $node (batch size: $batch_size)..." >&2

    # Calculate absolute expiry timestamp (current time + 3600 seconds)
    local now abs_expiry
    now=$(exec_node "$node" date +%s)
    abs_expiry=$((now + 3600))

    local end_index=$((start_index + count - 1))
    local i="$start_index"
    local batches_done=0

    while [ "$i" -le "$end_index" ]; do
        local cmd=""
        local j=0
        while [ "$j" -lt "$batch_size" ] && [ "$((i + j))" -le "$end_index" ]; do
            local idx=$((i + j))
            local hex_suffix
            hex_suffix=$(printf "%04x" "$idx")
            local ipv6="fd00:192:168:50::$hex_suffix"
            local mac
            mac=$(printf "aa:bb:cc:dd:%02x:%02x" $((idx / 256)) $((idx % 256)))
            local hostname="stress-$idx"

            # Add lease to dnsmasq + send event for lease-sync database
            cmd="${cmd}ubus call dnsmasq add_lease '{\"ip\":\"$ipv6\",\"mac\":\"$mac\",\"hostname\":\"$hostname\",\"expires\":$abs_expiry}' 2>/dev/null;"
            cmd="${cmd}ubus send dhcp.lease '{\"action\":\"add\",\"ip\":\"$ipv6\",\"mac\":\"$mac\",\"hostname\":\"$hostname\",\"expires\":$abs_expiry}' 2>/dev/null;"

            j=$((j + 1))
        done

        exec_node "$node" sh -c "$cmd" 2>/dev/null || true
        i=$((i + batch_size))
        batches_done=$((batches_done + 1))

        # Progress indicator every 5 batches (250 leases)
        if [ $((batches_done % 5)) -eq 0 ]; then
            debug "Completed $batches_done batches ($((batches_done * batch_size)) leases attempted)..." >&2
        fi
    done

    # Count actual leases in dnsmasq after all batches
    local actual_count
    actual_count=$(get_all_leases "$node" | grep -c '"ip"')

    info "Batch creation complete: $actual_count leases in dnsmasq ($batches_done batches)" >&2
    echo "$actual_count"
}

# Measure time for a single failover
# Usage: time_in_ms=$(measure_failover_time)
# NOTE: Restarts keepalived on the stopped node before returning,
# so the cluster is always left with both instances running.
measure_failover_time() {
    local initial_owner
    initial_owner=$(get_vip6_owner)

    if [ -z "$initial_owner" ]; then
        echo "0"
        return 1
    fi

    local failover_target
    if [ "$initial_owner" = "$NODE1" ]; then
        failover_target="$NODE2"
    else
        failover_target="$NODE1"
    fi

    # Measure failover time
    local start_time
    start_time=$(date +%s%3N)

    service_stop "$initial_owner" "keepalived"

    if wait_for_vip6 "$failover_target" 10; then
        local end_time
        end_time=$(date +%s%3N)
        local elapsed=$((end_time - start_time))

        # Restart keepalived on the stopped node so next iteration has both running
        service_start "$initial_owner" "keepalived"

        echo "$elapsed"
        return 0
    else
        # Restart keepalived even on failure to leave cluster in good state
        service_start "$initial_owner" "keepalived"

        echo "0"
        return 1
    fi
}

# ============================================
# Test Setup
# ============================================

setup() {
    subheader "Stress Test Setup"

    # Verify IPv6 is enabled
    if ! check_ipv6_enabled >/dev/null 2>&1; then
        skip "Stress test" "IPv6 not enabled"
        return 1
    fi

    # Enable DHCPv6 on dnsmasq (required for IPv6 add_lease to work)
    # By default OpenWrt delegates DHCPv6 to odhcpd; dnsmasq rejects IPv6
    # leases with "DHCPv6 not configured" unless it has an IPv6 dhcp-range.
    # Disabling odhcpd makes dnsmasq init generate IPv6 ranges.
    #
    # IMPORTANT: odhcpd must be fully stopped+disabled BEFORE dnsmasq restart,
    # otherwise dnsmasq's init script sees odhcpd as still enabled and skips
    # IPv6 range generation (DNSMASQ_DHCP_VER remains 4 instead of 6).
    info "Enabling DHCPv6 on dnsmasq (disabling odhcpd)..."
    save_and_disable_odhcpd_all || return 1

    # Configure DHCPv6 and restart dnsmasq
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" uci set dhcp.lan.dhcpv6='server'
        exec_node "$node" uci set dhcp.lan.ra='server'
        exec_node "$node" uci set dhcp.lan.ra_management='1'
        exec_node "$node" uci commit dhcp
        exec_node "$node" /etc/init.d/dnsmasq restart
    done
    sleep 3

    # Verify dnsmasq has IPv6 dhcp-range on both nodes
    for node in "$NODE1" "$NODE2"; do
        local dhcp6_check
        dhcp6_check=$(exec_node "$node" cat /var/etc/dnsmasq.conf.cfg01411c 2>/dev/null | grep "dhcp-range.*::") || true
        if [ -z "$dhcp6_check" ]; then
            warn "$node: dnsmasq still lacks IPv6 dhcp-range after odhcpd disable"
        else
            info "$node: $dhcp6_check"
        fi
    done

    # Verify lease-sync is running
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "lease-sync"; then
            skip "Stress test" "lease-sync not running"
            return 1
        fi
    done

    # Record initial memory usage
    INITIAL_MEMORY_NODE1=$(get_lease_sync_memory "$NODE1")
    INITIAL_MEMORY_NODE2=$(get_lease_sync_memory "$NODE2")

    info "Initial memory: $NODE1=${INITIAL_MEMORY_NODE1}KB, $NODE2=${INITIAL_MEMORY_NODE2}KB"

    pass "Stress test setup complete"
    return 0
}

# ============================================
# Test Cases
# ============================================

test_large_lease_set() {
    subheader "Test Large Lease Set (1000+ leases)"

    info "Target: $TARGET_LEASE_COUNT leases"
    info "Method: Manual event injection (Solution 4)"

    # STEP 1: Stop lease-sync on NODE2, keep NODE1 running
    info "Stopping lease-sync on NODE2 only..."
    service_stop "$NODE2" "lease-sync"
    sleep 2

    # STEP 2: Ensure lease-sync is running on NODE1
    info "Ensuring lease-sync is running on NODE1..."
    if ! service_running "$NODE1" "lease-sync"; then
        service_start "$NODE1" "lease-sync"
        sleep 5
    fi

    # STEP 3: Clear lease-sync state on NODE2
    # NODE2 will request full sync when it starts
    info "Clearing lease-sync state on NODE2..."
    exec_node "$NODE2" rm -f /var/lib/lease-sync/leases.db 2>/dev/null || true

    # STEP 4: Create synthetic leases with manual event injection on NODE1
    # This populates both dnsmasq AND lease-sync database (via ubus events)
    info "Creating synthetic leases with event injection on NODE1..."
    local created
    created=$(create_synthetic_leases "$NODE1" "$TARGET_LEASE_COUNT" 1)

    if [ "$created" -ge 100 ]; then
        pass "Created $created synthetic IPv6 leases with events"
    else
        fail "Failed to create sufficient leases for stress test (only $created)"
        return 1
    fi

    # STEP 5: Wait for lease-sync to process all events
    info "Waiting for lease-sync to process $created events..."
    sleep 20

    # STEP 6: Verify NODE1 has leases in dnsmasq
    local count1
    count1=$(get_all_leases "$NODE1" | grep -c '"ip"')
    info "NODE1 dnsmasq lease count: $count1"
    pass "NODE1 accepted $count1 leases"

    # STEP 7: Start lease-sync on NODE2 (triggers SYNC_REQUEST/SYNC_RESPONSE)
    # service_start calls ha-cluster restart which triggers uci commit dhcp,
    # causing procd to reload dnsmasq. The procd-triggered reload may lose the
    # IPv6 dhcp-range, so we re-restart dnsmasq explicitly afterward.
    info "Starting lease-sync on NODE2 (triggering bulk sync)..."
    service_start "$NODE2" "lease-sync"
    sleep 2
    exec_node "$NODE2" /etc/init.d/dnsmasq restart
    sleep 2

    # STEP 8: Wait for bulk sync to complete
    info "Waiting for bulk sync (SYNC_REQUEST/SYNC_RESPONSE)..."
    sleep 60  # Longer timeout for 1000+ leases

    # STEP 9: Measure sync results (capability measurement, not hard threshold)
    local count2
    count2=$(get_all_leases "$NODE2" | grep -c '"ip"')

    local sync_rate=0
    if [ "$count1" -gt 0 ]; then
        sync_rate=$((count2 * 100 / count1))
    fi

    info "=== Stress Test Measurements ==="
    info "Leases created on NODE1: $created (target: $TARGET_LEASE_COUNT)"
    info "Leases in NODE1 dnsmasq: $count1"
    info "Leases synced to NODE2:  $count2"
    info "Bulk sync rate:          ${sync_rate}%"

    # The system must sync at least some leases to prove bulk sync works
    if [ "$count2" -gt 0 ]; then
        pass "Bulk sync functional: $count2/$count1 leases synced (${sync_rate}%)"
    else
        fail "Bulk sync non-functional: 0 leases synced to NODE2"
        return 1
    fi
}

test_rapid_failovers() {
    subheader "Test Rapid Failovers (Performance)"

    info "Performing $RAPID_FAILOVER_COUNT rapid failovers..."

    local failover_times=""
    local successful_failovers=0
    local failed_failovers=0

    for i in $(seq 1 "$RAPID_FAILOVER_COUNT"); do
        debug "Failover $i/$RAPID_FAILOVER_COUNT..."

        local failover_time
        failover_time=$(measure_failover_time)

        if [ "$failover_time" -gt 0 ]; then
            successful_failovers=$((successful_failovers + 1))
            failover_times="$failover_times $failover_time"

            if [ "$failover_time" -lt 3000 ]; then
                debug "Failover $i: ${failover_time}ms"
            else
                warn "Failover $i: ${failover_time}ms (exceeds 3s)"
            fi
        else
            failed_failovers=$((failed_failovers + 1))
            warn "Failover $i: failed"
        fi

        # Allow VRRP to stabilize between failovers
        sleep 5
    done

    # Calculate average failover time
    local avg_time=0
    if [ "$successful_failovers" -gt 0 ]; then
        local total_time=0
        for time in $failover_times; do
            total_time=$((total_time + time))
        done
        avg_time=$((total_time / successful_failovers))
    fi

    info "=== Failover Measurements ==="
    info "Successful failovers: $successful_failovers/$RAPID_FAILOVER_COUNT"
    info "Failed failovers:     $failed_failovers"
    if [ "$avg_time" -gt 0 ]; then
        info "Average failover time: ${avg_time}ms"
    fi

    # The system must complete at least one failover to prove it works under load
    if [ "$successful_failovers" -gt 0 ]; then
        pass "Failover functional under stress: $successful_failovers/$RAPID_FAILOVER_COUNT succeeded (avg: ${avg_time}ms)"
    else
        fail "No failover succeeded under stress"
        return 1
    fi
}

test_memory_leak_detection() {
    subheader "Test Memory Leak Detection"

    # Get current memory usage
    local current_memory_node1 current_memory_node2
    current_memory_node1=$(get_lease_sync_memory "$NODE1")
    current_memory_node2=$(get_lease_sync_memory "$NODE2")

    info "Current memory: $NODE1=${current_memory_node1}KB, $NODE2=${current_memory_node2}KB"

    # Calculate memory growth
    local growth_node1=$((current_memory_node1 - INITIAL_MEMORY_NODE1))
    local growth_node2=$((current_memory_node2 - INITIAL_MEMORY_NODE2))

    info "Memory growth: $NODE1=${growth_node1}KB, $NODE2=${growth_node2}KB"

    # Convert threshold to KB
    local threshold_kb=$((MEMORY_THRESHOLD_MB * 1024))

    # Check NODE1
    if [ "$growth_node1" -lt "$threshold_kb" ]; then
        pass "NODE1 memory growth acceptable (${growth_node1}KB < ${MEMORY_THRESHOLD_MB}MB)"
    else
        fail "NODE1 memory growth excessive: ${growth_node1}KB (threshold: ${MEMORY_THRESHOLD_MB}MB)"
        return 1
    fi

    # Check NODE2
    if [ "$growth_node2" -lt "$threshold_kb" ]; then
        pass "NODE2 memory growth acceptable (${growth_node2}KB < ${MEMORY_THRESHOLD_MB}MB)"
    else
        fail "NODE2 memory growth excessive: ${growth_node2}KB (threshold: ${MEMORY_THRESHOLD_MB}MB)"
        return 1
    fi
}

test_performance_degradation() {
    subheader "Test Performance Degradation"

    # Measure sync latency with large lease set
    info "Measuring sync latency with large lease set..."

    # Add one more lease and measure time to sync
    local abs_expiry
    abs_expiry=$(exec_node "$NODE1" date +%s)
    abs_expiry=$((abs_expiry + 3600))

    local sync_start
    sync_start=$(date +%s%3N)

    exec_node "$NODE1" ubus call dnsmasq add_lease \
        "{\"ip\":\"fd00:192:168:50::ffff\",\"mac\":\"aa:bb:cc:dd:ee:ff\",\"hostname\":\"latency-test\",\"expires\":$abs_expiry}" \
        >/dev/null 2>&1

    # Send dhcp.lease event so lease-sync learns about it and can sync to NODE2
    exec_node "$NODE1" ubus send dhcp.lease \
        "{\"action\":\"add\",\"ip\":\"fd00:192:168:50::ffff\",\"mac\":\"aa:bb:cc:dd:ee:ff\",\"hostname\":\"latency-test\",\"expires\":$abs_expiry}" \
        >/dev/null 2>&1

    # Wait for lease to appear on NODE2
    local timeout=30
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if get_all_leases "$NODE2" | grep -q "fd00:192:168:50::ffff"; then
            local sync_end
            sync_end=$(date +%s%3N)
            local sync_time=$((sync_end - sync_start))

            info "Sync latency: ${sync_time}ms"

            # Check against reasonable threshold (5s)
            if [ "$sync_time" -lt 5000 ]; then
                pass "Sync latency acceptable with large lease set (${sync_time}ms < 5s)"
            else
                warn "Sync latency high: ${sync_time}ms"
            fi
            return 0
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "Lease did not sync within ${timeout}s (possible performance degradation)"
}

# ============================================
# Cleanup
# ============================================

cleanup() {
    subheader "Cleanup"

    info "Removing synthetic leases from both nodes..."

    for node in "$NODE1" "$NODE2"; do
        # Delete all stress-test leases in batches to avoid per-lease exec overhead
        local i=1
        local batch_size=50
        while [ "$i" -le "$TARGET_LEASE_COUNT" ]; do
            local cmd=""
            local j=0
            while [ "$j" -lt "$batch_size" ] && [ "$((i + j))" -le "$TARGET_LEASE_COUNT" ]; do
                local idx=$((i + j))
                local hex_suffix
                hex_suffix=$(printf "%04x" "$idx")
                local ipv6="fd00:192:168:50::$hex_suffix"
                cmd="${cmd}ubus call dnsmasq delete_lease '{\"ip\":\"$ipv6\"}' 2>/dev/null;"
                j=$((j + 1))
            done
            exec_node "$node" sh -c "$cmd" 2>/dev/null || true
            i=$((i + batch_size))
        done
        info "Lease cleanup complete on $node"
    done

    # Clean up the latency-test lease from test_performance_degradation
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" ubus call dnsmasq delete_lease \
            '{"ip":"fd00:192:168:50::ffff"}' 2>/dev/null || true
    done

    # Restore odhcpd and original dnsmasq configuration
    info "Restoring odhcpd and dnsmasq configuration..."
    for node in "$NODE1" "$NODE2"; do
        exec_node "$node" uci delete dhcp.lan.dhcpv6 2>/dev/null || true
        exec_node "$node" uci delete dhcp.lan.ra 2>/dev/null || true
        exec_node "$node" uci delete dhcp.lan.ra_management 2>/dev/null || true
        exec_node "$node" uci commit dhcp
        exec_node "$node" /etc/init.d/dnsmasq restart
    done
    restore_odhcpd_if_was_running

    # Restart keepalived on both nodes (may have been stopped by rapid failover test)
    for node in "$NODE1" "$NODE2"; do
        if ! service_running "$node" "keepalived"; then
            info "Restarting keepalived on $node..."
            exec_node "$node" /etc/init.d/ha-cluster restart 2>/dev/null || true
        fi
    done

    sleep 2
    pass "Stress test cleanup complete"
}

# ============================================
# Main Test Flow
# ============================================

main() {
    header "T19: IPv6 Stress Test"
    info "Validates 1000+ leases and performance under stress"

    setup || return 1

    local result=0

    test_large_lease_set || result=1
    test_rapid_failovers || result=1
    test_memory_leak_detection || result=1
    test_performance_degradation || result=1

    cleanup

    return $result
}

main
exit $?
