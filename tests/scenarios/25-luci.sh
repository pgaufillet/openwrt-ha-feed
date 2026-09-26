#!/bin/sh
# 25-luci.sh - Test T25: LuCI Characterization
#
# Freezes the observable behaviour of the luci-app-ha-cluster pages on
# ha-node1, driven by Playwright (tests/luci/luci-test.js):
#
#   - snapshot: every page and edit modal rendered for each UCI fixture
#     (tests/luci/fixtures, old option names, migrated first by the
#     working-tree uci-defaults script)
#   - missing: pages rendered with the lease-sync or owsync binary removed
#   - action: UCI changes staged by scripted edits (Save, never Apply)
#   - layout: overflow, overlap, alignment, contrast of app colours and
#     unlabeled narrow cells, at 1280 and 375 px, light and dark
#
# and checks that the Status page shows what "ubus call ha-cluster status"
# returns and that no page logs an error to the console.
#
# The node config is restored at the end; nothing is applied, so the
# running daemons are untouched. Screenshots are left in logs/luci for
# review.
#
# CHAR_UPDATE=1 rewrites the expected files instead of comparing.
# LUCI_MIGRATION overrides the migration script; empty skips migration.
#
# Requires: node, "npm ci" in tests/ and "npx playwright install chromium".
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

LUCI_DIR="$TEST_DIR/luci"
FEED_DIR="$(dirname "$TEST_DIR")"
OUT_DIR="$TEST_DIR/logs/luci"
LUCI_MIGRATION="${LUCI_MIGRATION-$FEED_DIR/ha-cluster/files/ha-cluster.uci-defaults}"

# ============================================
# Helpers
# ============================================

# Rootless podman keeps container networks in its own namespace
run_in_netns() {
    if [ "$CONTAINER_RUNTIME" = "podman" ] &&
       [ "$(podman info --format '{{.Host.Security.Rootless}}')" = "true" ]; then
        podman unshare --rootless-netns "$@"
    else
        "$@"
    fi
}

# ============================================
# Test Cases
# ============================================

test_prerequisites() {
    subheader "Prerequisites"

    if ! command -v node >/dev/null 2>&1; then
        fail "node not found on the host"
        return 1
    fi
    if [ ! -d "$TEST_DIR/node_modules/playwright" ]; then
        fail "Playwright not installed (run 'npm ci' in $TEST_DIR)"
        return 1
    fi
    if ! $CONTAINER_RUNTIME exec "$NODE1" pgrep uhttpd >/dev/null 2>&1; then
        fail "uhttpd not running on $NODE1 (run setup.sh first)"
        return 1
    fi
    if [ -n "$LUCI_MIGRATION" ] && [ ! -f "$LUCI_MIGRATION" ]; then
        fail "Migration script not found: $LUCI_MIGRATION"
        return 1
    fi
    pass "node, Playwright and LuCI on $NODE1 available"
}

test_run() {
    subheader "Drive the LuCI pages"

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"

    if ! NODE_PATH="$TEST_DIR/node_modules" CONTAINER_RUNTIME="$CONTAINER_RUNTIME" \
        run_in_netns node "$LUCI_DIR/luci-test.js" \
            --node "$NODE1" --url "http://$NODE1_BACKEND_IP" --out "$OUT_DIR" \
            ${LUCI_MIGRATION:+--migration "$LUCI_MIGRATION"}; then
        fail "Playwright run failed"
        return 1
    fi
    pass "Pages driven (screenshots in $OUT_DIR/screenshots)"
}

test_status_matches_rpcd() {
    subheader "Status page vs rpcd"

    if grep -q '^MISMATCH' "$OUT_DIR/computed/status.out"; then
        fail "Status page differs from the rpcd status"
        grep '^MISMATCH' "$OUT_DIR/computed/status.out"
        return 1
    fi
    pass "Status page matches rpcd ($(grep -c '^ok' "$OUT_DIR/computed/status.out") fields)"
}

test_no_console_errors() {
    subheader "Console errors"

    if [ -s "$OUT_DIR/computed/console.out" ]; then
        fail "Pages logged errors"
        cat "$OUT_DIR/computed/console.out"
        return 1
    fi
    pass "No console errors"
}

# Usage: test_compare snapshot|missing|action|layout
test_compare() {
    local kind="$1"
    local rc=0
    local actual expected name diff_out

    subheader "Characterization: $kind"

    diff_out=$(mktemp)
    mkdir -p "$LUCI_DIR/expected/$kind"

    for actual in "$OUT_DIR/$kind/"*.out; do
        [ -f "$actual" ] || continue
        name=$(basename "$actual" .out)
        expected="$LUCI_DIR/expected/$kind/$name.out"

        if [ "$CHAR_UPDATE" = "1" ]; then
            cp "$actual" "$expected"
            info "Updated $kind/$name"
        elif [ ! -f "$expected" ]; then
            fail "$kind/$name: no expected output"
            rc=1
        elif diff -u "$expected" "$actual" > "$diff_out"; then
            pass "$kind/$name"
        else
            fail "$kind/$name: output differs from expected"
            cat "$diff_out"
            rc=1
        fi
    done

    for expected in "$LUCI_DIR/expected/$kind/"*.out; do
        [ -f "$expected" ] || continue
        name=$(basename "$expected" .out)
        if [ ! -f "$OUT_DIR/$kind/$name.out" ]; then
            fail "$kind/$name: expected output was not produced"
            rc=1
        fi
    done

    rm -f "$diff_out"
    return $rc
}

# ============================================
# Main
# ============================================

main() {
    header "T25: LuCI Characterization"
    info "Compares the LuCI pages with the expected outputs"

    local result=0

    test_prerequisites || return 1
    test_run || return 1

    test_status_matches_rpcd || result=1
    test_no_console_errors || result=1
    for kind in snapshot missing action layout; do
        test_compare "$kind" || result=1
    done

    return $result
}

main
exit $?
