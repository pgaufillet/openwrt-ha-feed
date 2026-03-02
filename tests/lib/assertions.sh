#!/bin/sh
# assertions.sh - Test assertion helpers for HA cluster testing
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# Requires: lib/common.sh to be sourced first
#
# Usage: Source after common.sh:
#   . ./lib/common.sh
#   . ./lib/assertions.sh

# ============================================
# Basic Assertions
# ============================================

# Assert that a command succeeds (returns 0)
# Usage: assert_success "Test name" command arg1 arg2 ...
assert_success() {
    local test_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (command failed: $*)"
        return 1
    fi
}

# Assert that a command fails (returns non-zero)
# Usage: assert_failure "Test name" command arg1 arg2 ...
assert_failure() {
    local test_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$test_name (expected failure but succeeded)"
        return 1
    else
        pass "$test_name"
        return 0
    fi
}

# Assert that two values are equal
# Usage: assert_eq "expected" "actual" "Test name"
assert_eq() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (expected: '$expected', got: '$actual')"
        return 1
    fi
}

# Assert that two values are not equal
# Usage: assert_ne "unexpected" "actual" "Test name"
assert_ne() {
    local unexpected="$1"
    local actual="$2"
    local test_name="$3"
    if [ "$unexpected" != "$actual" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (expected not '$unexpected', got: '$actual')"
        return 1
    fi
}

# Assert that a string contains a substring
# Usage: assert_contains "haystack" "needle" "Test name"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local test_name="$3"
    case "$haystack" in
        *"$needle"*)
            pass "$test_name"
            return 0
            ;;
        *)
            fail "$test_name (expected '$haystack' to contain '$needle')"
            return 1
            ;;
    esac
}

# Assert that a string does not contain a substring
# Usage: assert_not_contains "haystack" "needle" "Test name"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local test_name="$3"
    case "$haystack" in
        *"$needle"*)
            fail "$test_name (expected '$haystack' to NOT contain '$needle')"
            return 1
            ;;
        *)
            pass "$test_name"
            return 0
            ;;
    esac
}

# ============================================
# File Assertions
# ============================================

# Assert that a file exists
# Usage: assert_file_exists "Test name" "/path/to/file"
assert_file_exists() {
    local test_name="$1"
    local file_path="$2"
    if [ -f "$file_path" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (file not found: $file_path)"
        return 1
    fi
}

# Assert that a file does not exist
# Usage: assert_file_not_exists "Test name" "/path/to/file"
assert_file_not_exists() {
    local test_name="$1"
    local file_path="$2"
    if [ ! -f "$file_path" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (file exists but should not: $file_path)"
        return 1
    fi
}

# Assert that a directory exists
# Usage: assert_dir_exists "Test name" "/path/to/dir"
assert_dir_exists() {
    local test_name="$1"
    local dir_path="$2"
    if [ -d "$dir_path" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (directory not found: $dir_path)"
        return 1
    fi
}

# ============================================
# Numeric Assertions
# ============================================

# Assert that a number is greater than another
# Usage: assert_gt "actual" "threshold" "Test name"
assert_gt() {
    local actual="$1"
    local threshold="$2"
    local test_name="$3"
    if [ "$actual" -gt "$threshold" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (expected $actual > $threshold)"
        return 1
    fi
}

# Assert that a number is less than another
# Usage: assert_lt "actual" "threshold" "Test name"
assert_lt() {
    local actual="$1"
    local threshold="$2"
    local test_name="$3"
    if [ "$actual" -lt "$threshold" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (expected $actual < $threshold)"
        return 1
    fi
}

# Assert that a number is in a range
# Usage: assert_in_range "actual" "min" "max" "Test name"
assert_in_range() {
    local actual="$1"
    local min="$2"
    local max="$3"
    local test_name="$4"
    if [ "$actual" -ge "$min" ] && [ "$actual" -le "$max" ]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (expected $min <= $actual <= $max)"
        return 1
    fi
}

# ============================================
# Process Assertions
# ============================================

# Assert that a process is running
# Usage: assert_process_running "Test name" "process_name"
assert_process_running() {
    local test_name="$1"
    local proc_name="$2"
    if pgrep -x "$proc_name" >/dev/null 2>&1; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (process '$proc_name' not running)"
        return 1
    fi
}

# Assert that a process is not running
# Usage: assert_process_not_running "Test name" "process_name"
assert_process_not_running() {
    local test_name="$1"
    local proc_name="$2"
    if ! pgrep -x "$proc_name" >/dev/null 2>&1; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (process '$proc_name' is running but should not be)"
        return 1
    fi
}

# ============================================
# Network Assertions
# ============================================

# Assert that a host is reachable via ping
# Usage: assert_ping "Test name" "host" [timeout]
assert_ping() {
    local test_name="$1"
    local host="$2"
    local timeout="${3:-5}"
    if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (host '$host' not reachable)"
        return 1
    fi
}

# Assert that a port is listening
# Usage: assert_port_open "Test name" "host" "port"
assert_port_open() {
    local test_name="$1"
    local host="$2"
    local port="$3"
    if nc -z "$host" "$port" 2>/dev/null; then
        pass "$test_name"
        return 0
    else
        fail "$test_name (port $port not open on $host)"
        return 1
    fi
}
