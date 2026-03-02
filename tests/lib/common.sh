#!/bin/sh
# common.sh - Core test framework utilities for HA cluster testing
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# Usage: Source this file in test scripts:
#   . ./lib/common.sh

# ============================================
# Color Codes (ANSI escape sequences)
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

# ============================================
# Test Counters
# ============================================
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_NONFATAL=0
CURRENT_TEST=""

# Track non-fatal test names for summary
NONFATAL_TESTS=""

# ============================================
# Configuration
# ============================================

# Container runtime (detect podman or docker)
detect_runtime() {
    if command -v podman >/dev/null 2>&1; then
        echo "podman"
    elif command -v docker >/dev/null 2>&1; then
        echo "docker"
    else
        echo ""
    fi
}

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(detect_runtime)}"

# Default configuration (can be overridden)
NODE1="${NODE1:-ha-node1}"
NODE2="${NODE2:-ha-node2}"
NODE3="${NODE3:-ha-node3}"
NODE1_BACKEND_IP="${NODE1_BACKEND_IP:-172.30.0.10}"
NODE2_BACKEND_IP="${NODE2_BACKEND_IP:-172.30.0.11}"
NODE3_BACKEND_IP="${NODE3_BACKEND_IP:-172.30.0.12}"
NODE1_CLIENT_IP="${NODE1_CLIENT_IP:-192.168.50.10}"
NODE2_CLIENT_IP="${NODE2_CLIENT_IP:-192.168.50.11}"
NODE3_CLIENT_IP="${NODE3_CLIENT_IP:-192.168.50.12}"
VIP_ADDRESS="${VIP_ADDRESS:-192.168.50.254}"
VIP_NETMASK="${VIP_NETMASK:-255.255.255.0}"

# Timeouts (seconds)
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
FAILOVER_TIMEOUT="${FAILOVER_TIMEOUT:-15}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-30}"

# Test encryption key
TEST_KEY="7f8e9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e"

# ============================================
# Output Functions
# ============================================

# Print a test section header
header() {
    printf "\n"
    printf "==========================================\n"
    printf "${CYAN}%s${NC}\n" "$1"
    printf "==========================================\n"
}

# Print a subsection header
subheader() {
    printf "\n${YELLOW}--- %s ---${NC}\n" "$1"
}

# Print informational message
info() {
    printf "${BLUE}→${NC} %s\n" "$1"
}

# Print debug message (only if DEBUG is set)
debug() {
    [ -n "$DEBUG" ] && printf "${CYAN}[DEBUG]${NC} %s\n" "$1"
}

# Print warning message (to stderr so it doesn't affect captured output)
warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
}

# ============================================
# Test Result Functions
# ============================================

# Start a test (for tracking purposes)
test_start() {
    CURRENT_TEST="$1"
    printf "${BLUE}[TEST]${NC} %s ... " "$1"
}

# Mark current test as passed
pass() {
    local msg="${1:-$CURRENT_TEST}"
    printf "${GREEN}[PASS]${NC} %s\n" "$msg"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    CURRENT_TEST=""
}

# Mark current test as failed
fail() {
    local msg="${1:-$CURRENT_TEST}"
    printf "${RED}[FAIL]${NC} %s\n" "$msg"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    CURRENT_TEST=""
}

# Mark current test as skipped
skip() {
    local msg="${1:-$CURRENT_TEST}"
    local reason="${2:-}"
    if [ -n "$reason" ]; then
        printf "${YELLOW}[SKIP]${NC} %s (reason: %s)\n" "$msg" "$reason"
    else
        printf "${YELLOW}[SKIP]${NC} %s\n" "$msg"
    fi
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    CURRENT_TEST=""
}

# Mark current test as non-fatal failure
# Use this for tests that may fail due to environment limitations but
# shouldn't cause the overall test suite to fail.
# Usage: nonfatal "test name" "reason why it's non-fatal"
nonfatal() {
    local msg="${1:-$CURRENT_TEST}"
    local reason="${2:-}"
    if [ -n "$reason" ]; then
        printf "${YELLOW}[NONFATAL]${NC} %s (reason: %s)\n" "$msg" "$reason"
    else
        printf "${YELLOW}[NONFATAL]${NC} %s\n" "$msg"
    fi
    TESTS_NONFATAL=$((TESTS_NONFATAL + 1))
    # Track non-fatal test names for summary
    if [ -n "$NONFATAL_TESTS" ]; then
        NONFATAL_TESTS="${NONFATAL_TESTS}, ${msg}"
    else
        NONFATAL_TESTS="$msg"
    fi
    CURRENT_TEST=""
}

# Record test result based on status code
test_result() {
    local status="$1"
    local name="$2"
    if [ "$status" -eq 0 ]; then
        pass "$name"
    else
        fail "$name"
    fi
}

# Run a test function as non-fatal
# Usage: run_nonfatal test_function_name "reason why non-fatal"
# Returns: always 0 (test suite continues regardless of result)
run_nonfatal() {
    local test_fn="$1"
    local reason="$2"

    if "$test_fn"; then
        # Test passed - no action needed (test function records its own passes)
        :
    else
        # Test failed - record as non-fatal
        nonfatal "$test_fn" "$reason"
    fi
    return 0
}

# ============================================
# Test Summary
# ============================================

# Print test summary and return appropriate exit code
summary() {
    printf "\n"
    printf "==========================================\n"
    printf "Test Summary\n"
    printf "==========================================\n"
    printf "Passed:   ${GREEN}%d${NC}\n" "$TESTS_PASSED"
    printf "Failed:   ${RED}%d${NC}\n" "$TESTS_FAILED"
    printf "Non-fatal: ${YELLOW}%d${NC}\n" "$TESTS_NONFATAL"
    printf "Skipped:  ${YELLOW}%d${NC}\n" "$TESTS_SKIPPED"
    printf "Total:    %d\n" "$((TESTS_PASSED + TESTS_FAILED + TESTS_NONFATAL + TESTS_SKIPPED))"

    # Show non-fatal test names if any
    if [ "$TESTS_NONFATAL" -gt 0 ] && [ -n "$NONFATAL_TESTS" ]; then
        printf "\nNon-fatal failures: %s\n" "$NONFATAL_TESTS"
    fi

    if [ "$TESTS_FAILED" -eq 0 ]; then
        if [ "$TESTS_NONFATAL" -gt 0 ]; then
            printf "\n${GREEN}All critical tests passed!${NC} (%d non-fatal failures)\n" "$TESTS_NONFATAL"
        else
            printf "\n${GREEN}All tests passed!${NC}\n"
        fi
        return 0
    else
        printf "\n${RED}Some tests failed!${NC}\n"
        return 1
    fi
}

# Reset test counters (useful for running multiple test suites)
reset_counters() {
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    TESTS_NONFATAL=0
    NONFATAL_TESTS=""
}

# ============================================
# Utility Functions
# ============================================

# Check if container runtime is available
check_runtime() {
    if [ -z "$CONTAINER_RUNTIME" ]; then
        echo "Error: No container runtime found (podman or docker required)"
        return 1
    fi
    return 0
}

# Create a temporary directory
make_temp_dir() {
    mktemp -d 2>/dev/null || {
        local dir="/tmp/ha-test-$$-$(date +%s)"
        mkdir -p "$dir"
        echo "$dir"
    }
}

# Clean up temporary directory
cleanup_temp_dir() {
    [ -n "$1" ] && [ -d "$1" ] && rm -rf "$1"
}

# Wait for a condition with timeout
# Usage: wait_for "description" timeout_seconds "test_command"
wait_for() {
    local desc="$1"
    local timeout="$2"
    shift 2
    local cmd="$*"

    local count=0
    debug "Waiting for: $desc (timeout: ${timeout}s)"
    while [ $count -lt "$timeout" ]; do
        if eval "$cmd" >/dev/null 2>&1; then
            debug "Condition met after ${count}s"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    debug "Timeout waiting for: $desc"
    return 1
}

# Log to file and optionally stdout
log_to_file() {
    local logfile="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$logfile"
}
