#!/bin/sh
# 24-characterization.sh - Test T24: Backend, rpcd, ACL and Migration Characterization
#
# Freezes the observable behaviour of the ha-cluster backend and of the
# rpcd status method over a matrix of configurations, so that any change
# to it shows up as a diff against the expected output:
#
#   - backend: start_service result, procd instances, log lines, generated
#     keepalived/owsync/lease-sync configs, dnsmasq overlay, saved
#     standalone-service state
#   - rpcd: "status" JSON for a given config, set of running daemons,
#     reachable peers and keepalived dump
#   - acl: what a LuCI user holding only the luci-base and app ACL groups
#     may call, through a real rpcd session
#   - migration: /etc/config/ha-cluster before and after the uci-defaults
#     migration, and after a second run
#
# Each case runs in a throwaway ha-cluster-node container (no network),
# against the working-tree scripts, with logger/pgrep/ubus/ping stubbed.
# Only the node image is needed, not a running cluster.
#
# CHAR_UPDATE=1 rewrites the expected files instead of comparing.
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

# ============================================
# Configuration
# ============================================

CHAR_DIR="$TEST_DIR/characterization"
FEED_DIR="$(dirname "$TEST_DIR")"
NODE_IMAGE="${NODE_IMAGE:-ha-cluster-node:latest}"

# ============================================
# Helpers
# ============================================

# Usage: run_case backend|rpcd|acl|migration <case file name>
run_case() {
    local mode="$1"
    local case_name="$2"

    $CONTAINER_RUNTIME run --rm --network none --hostname ha-char \
        --entrypoint /bin/sh \
        -v "$FEED_DIR/ha-cluster/files/ha-cluster.sh:/usr/lib/ha-cluster/ha-cluster.sh:ro" \
        -v "$FEED_DIR/ha-cluster/files/ha-cluster.init:/etc/init.d/ha-cluster:ro" \
        -v "$FEED_DIR/ha-cluster/files/ha-cluster.config:/shipped/ha-cluster:ro" \
        -v "$FEED_DIR/ha-cluster/files/ha-cluster.uci-defaults:/char-migrate:ro" \
        -v "$FEED_DIR/luci-app-ha-cluster/root/usr/libexec/rpcd/ha-cluster:/usr/libexec/rpcd/ha-cluster:ro" \
        -v "$FEED_DIR/luci-app-ha-cluster/root/usr/share/rpcd/acl.d/luci-app-ha-cluster.json:/usr/share/rpcd/acl.d/luci-app-ha-cluster.json:ro" \
        -v "$CHAR_DIR:/char:ro" \
        "$NODE_IMAGE" /char/harness.sh "$mode" "/char/$mode/cases/$case_name"
}

# Pretty-print the rpcd JSON (last line) so that diffs are per field
format_output() {
    local mode="$1"
    local file="$2"

    if [ "$mode" = "rpcd" ]; then
        sed '$d' "$file"
        tail -n 1 "$file" | python3 -m json.tool
    else
        cat "$file"
    fi
}

# ============================================
# Test Cases
# ============================================

test_prerequisites() {
    subheader "Prerequisites"

    if ! $CONTAINER_RUNTIME image inspect "$NODE_IMAGE" >/dev/null 2>&1; then
        fail "Image $NODE_IMAGE not found (run setup.sh first)"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 not found on the host (needed to format rpcd JSON)"
        return 1
    fi
    pass "Node image and python3 available"
}

# Usage: test_matrix backend|rpcd|acl|migration
test_matrix() {
    local mode="$1"
    local rc=0
    local case_file case_name expected raw actual errors

    subheader "Characterization: $mode"

    raw=$(mktemp)
    actual=$(mktemp)
    errors=$(mktemp)

    for case_file in "$CHAR_DIR/$mode/cases/"*.sh; do
        case_name=$(basename "$case_file" .sh)
        expected="$CHAR_DIR/expected/$mode/$case_name.out"

        if ! run_case "$mode" "$case_name.sh" > "$raw" 2> "$errors"; then
            fail "$mode/$case_name: case run failed"
            cat "$raw" "$errors"
            rc=1
            continue
        fi
        [ -s "$errors" ] && warn "$mode/$case_name: $(cat "$errors")"
        if ! format_output "$mode" "$raw" > "$actual"; then
            fail "$mode/$case_name: output cannot be formatted"
            cat "$raw"
            rc=1
            continue
        fi

        if [ "$CHAR_UPDATE" = "1" ]; then
            cp "$actual" "$expected"
            info "Updated $mode/$case_name"
        elif [ ! -f "$expected" ]; then
            fail "$mode/$case_name: no expected output"
            rc=1
        elif diff -u "$expected" "$actual" > "$raw"; then
            pass "$mode/$case_name"
        else
            fail "$mode/$case_name: output differs from expected"
            cat "$raw"
            rc=1
        fi
    done

    for expected in "$CHAR_DIR/expected/$mode/"*.out; do
        case_name=$(basename "$expected" .out)
        if [ ! -f "$CHAR_DIR/$mode/cases/$case_name.sh" ]; then
            fail "$mode/$case_name: expected output without a case"
            rc=1
        fi
    done

    rm -f "$raw" "$actual" "$errors"
    return $rc
}

# ============================================
# Main
# ============================================

main() {
    header "T24: Backend, rpcd, ACL and Migration Characterization"
    info "Compares backend, rpcd, ACL and migration behaviour with the expected outputs"

    local result=0

    test_prerequisites || return 1

    test_matrix backend || result=1
    test_matrix rpcd || result=1
    test_matrix acl || result=1
    test_matrix migration || result=1

    return $result
}

main
exit $?
