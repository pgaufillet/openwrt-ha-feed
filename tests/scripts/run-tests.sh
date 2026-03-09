#!/bin/sh
# run-tests.sh - Execute HA cluster test scenarios
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Usage:
#   ./run-tests.sh                  # Run Priority 1 tests (T01-T05)
#   ./run-tests.sh --all            # Run all tests
#   ./run-tests.sh 03-vrrp-failover # Run specific test
#   ./run-tests.sh --list           # List available tests

set -e

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

RUN_ALL=false
SPECIFIC_TEST=""
LIST_TESTS=false
VERBOSE=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --all|-a)
            RUN_ALL=true
            ;;
        --list|-l)
            LIST_TESTS=true
            ;;
        --verbose|-v)
            VERBOSE=true
            DEBUG=1
            ;;
        --help|-h)
            echo "Usage: $0 [options] [test_name]"
            echo ""
            echo "Options:"
            echo "  --all, -a       Run all tests (including Priority 2 and 3)"
            echo "  --list, -l      List available tests"
            echo "  --verbose, -v   Enable verbose output"
            echo "  --help, -h      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                      # Run Priority 1 tests"
            echo "  $0 --all                # Run all tests"
            echo "  $0 03-vrrp-failover     # Run specific test"
            echo "  $0 01 02 03             # Run multiple specific tests"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            # Positional argument - test name
            SPECIFIC_TEST="$SPECIFIC_TEST $1"
            ;;
    esac
    shift
done

# ============================================
# Test Discovery
# ============================================

# Find all test scenarios
find_tests() {
    ls -1 "$TEST_DIR/scenarios"/*.sh 2>/dev/null | sort
}

# List available tests
list_tests() {
    header "Available Test Scenarios"

    echo ""
    echo "Priority 1 (Must Have):"
    for f in "$TEST_DIR/scenarios"/0[1-5]-*.sh; do
        [ -f "$f" ] && echo "  $(basename "$f" .sh)"
    done

    echo ""
    echo "Priority 2 (Should Have):"
    for f in "$TEST_DIR/scenarios"/0[6-8]-*.sh; do
        [ -f "$f" ] && echo "  $(basename "$f" .sh)"
    done

    echo ""
    echo "Priority 3 (Nice to Have):"
    for f in "$TEST_DIR/scenarios"/0[9]-*.sh "$TEST_DIR/scenarios"/[1-9][0-9]-*.sh; do
        [ -f "$f" ] && echo "  $(basename "$f" .sh)"
    done
}

# ============================================
# Cluster Stabilization
# ============================================

# Stabilize cluster between tests to ensure deterministic state
# This prevents state leakage and resets procd respawn counters if needed
stabilize_cluster() {
    # Disable exit-on-error for this function - we handle errors explicitly
    set +e

    debug "Checking cluster health after test..."

    # Reset DHCP client state to prevent interference between tests
    # Tests like T05/T06/T07/T08 use DHCP clients and can leave them in inconsistent states
    # dhcpcd stores state in /var/lib/dhcpcd/ which causes rebind instead of new lease request
    for client in "$CLIENT1" "$CLIENT2"; do
        if client_running "$client" 2>/dev/null; then
            debug "Resetting DHCP client on $client..."
            exec_client "$client" dhcpcd -k eth0 2>/dev/null || true
            exec_client "$client" ip addr flush dev eth0 2>/dev/null || true
            # Clear dhcpcd state files to force fresh DHCP discovery
            exec_client "$client" rm -f /var/lib/dhcpcd/eth0.lease /var/lib/dhcpcd/duid 2>/dev/null || true
        fi
    done

    # Quick health check - are basic services running?
    local health_result
    wait_for_cluster_healthy 10 >/dev/null 2>&1
    health_result=$?

    if [ $health_result -eq 0 ]; then
        debug "Cluster healthy, no stabilization needed"
        set -e
        return 0
    fi

    # Cluster not healthy - need to reset
    warn "Cluster not healthy after test, resetting ha-cluster services..."

    # Restart ha-cluster on both nodes (resets procd instance state including respawn counters)
    for node in "$NODE1" "$NODE2"; do
        debug "Restarting ha-cluster on $node..."
        exec_node "$node" /etc/init.d/ha-cluster restart >/dev/null 2>&1 || true
    done

    # Wait for cluster to recover
    wait_for_cluster_healthy 30 >/dev/null 2>&1
    health_result=$?

    if [ $health_result -eq 0 ]; then
        info "Cluster stabilized after reset"
        set -e
        return 0
    else
        warn "Cluster failed to stabilize - subsequent tests may fail"
        set -e
        return 0  # Don't fail the test suite, just warn
    fi
}

# ============================================
# Test Execution
# ============================================

# Run a single test scenario
run_test() {
    local test_file="$1"
    local test_name
    test_name=$(basename "$test_file" .sh)

    echo ""
    header "Running: $test_name"

    # Check if test file exists
    if [ ! -f "$test_file" ]; then
        # Try to find by partial name
        test_file=$(find_test_by_name "$test_name")
        if [ -z "$test_file" ]; then
            fail "Test not found: $test_name"
            return 1
        fi
    fi

    # Run the test
    if sh "$test_file"; then
        info "Test completed: $test_name"
        return 0
    else
        fail "Test failed: $test_name"
        return 1
    fi
}

# Find test file by partial name
find_test_by_name() {
    local name="$1"

    # Try exact match first
    if [ -f "$TEST_DIR/scenarios/${name}.sh" ]; then
        echo "$TEST_DIR/scenarios/${name}.sh"
        return 0
    fi

    # Try with prefix (01, 02, etc.)
    for f in "$TEST_DIR/scenarios"/*-"${name}"*.sh "$TEST_DIR/scenarios"/"${name}"-*.sh; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done

    # Try partial match
    for f in "$TEST_DIR/scenarios"/*.sh; do
        if echo "$f" | grep -qi "$name"; then
            echo "$f"
            return 0
        fi
    done

    return 1
}

# Run Priority 1 tests (default)
run_priority1() {
    header "Running Priority 1 Tests (T01-T05)"

    local failed=0
    for test_file in "$TEST_DIR/scenarios"/0[1-5]-*.sh; do
        if [ -f "$test_file" ]; then
            if ! run_test "$test_file"; then
                failed=$((failed + 1))
            fi
            # Stabilize cluster between tests for determinism
            stabilize_cluster
        fi
    done

    return $failed
}

# Run all tests
run_all_tests() {
    header "Running All Tests"

    local failed=0
    for test_file in $(find_tests); do
        if ! run_test "$test_file"; then
            failed=$((failed + 1))
        fi
        # Stabilize cluster between tests for determinism
        stabilize_cluster
    done

    return $failed
}

# Run specific tests
run_specific_tests() {
    header "Running Specific Tests"

    local failed=0
    local test_count=0
    for test_name in $SPECIFIC_TEST; do
        test_count=$((test_count + 1))
    done

    local current=0
    for test_name in $SPECIFIC_TEST; do
        current=$((current + 1))
        local test_file
        test_file=$(find_test_by_name "$test_name")
        if [ -n "$test_file" ]; then
            if ! run_test "$test_file"; then
                failed=$((failed + 1))
            fi
            # Stabilize cluster between tests (skip after last test)
            if [ $current -lt $test_count ]; then
                stabilize_cluster
            fi
        else
            fail "Test not found: $test_name"
            failed=$((failed + 1))
        fi
    done

    return $failed
}

# ============================================
# Pre-flight Checks
# ============================================

check_cluster_ready() {
    header "Checking Cluster Status"

    check_runtime || exit 1

    # Check containers are running
    info "Checking containers..."
    if ! node_running "$NODE1"; then
        echo "Error: Container $NODE1 is not running"
        echo "Run setup.sh first"
        exit 1
    fi
    if ! node_running "$NODE2"; then
        echo "Error: Container $NODE2 is not running"
        echo "Run setup.sh first"
        exit 1
    fi

    # Check basic services
    info "Checking services..."
    if ! service_running "$NODE1" "ubusd"; then
        echo "Error: ubusd not running on $NODE1"
        exit 1
    fi
    if ! service_running "$NODE2" "ubusd"; then
        echo "Error: ubusd not running on $NODE2"
        exit 1
    fi

    # Check connectivity
    info "Checking connectivity..."
    if ! nodes_can_communicate; then
        echo "Warning: Nodes cannot communicate"
    fi

    info "Cluster ready for testing"
}

# ============================================
# Main
# ============================================

main() {
    echo "========================================="
    echo "HA Cluster Test Runner"
    echo "========================================="

    # Handle --list
    if [ "$LIST_TESTS" = "true" ]; then
        list_tests
        exit 0
    fi

    # Pre-flight checks
    check_cluster_ready

    # Determine which tests to run
    local result=0
    if [ -n "$SPECIFIC_TEST" ]; then
        run_specific_tests
        result=$?
    elif [ "$RUN_ALL" = "true" ]; then
        run_all_tests
        result=$?
    else
        run_priority1
        result=$?
    fi

    # Print summary
    summary

    exit $result
}

main
