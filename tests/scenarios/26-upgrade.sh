#!/bin/sh
# 26-upgrade.sh - Test T26: Package Upgrade from the Previous Model
#
# Upgrades ha-cluster and luci-app-ha-cluster with apk, from the packages
# built before the sync model change (tests/packages/old/) to the ones in
# tests/packages/, on a node running the cluster with an old-model
# /etc/config/ha-cluster, and checks for each configuration:
#
#   - apk ran the new ha-cluster post-upgrade script, which consumed the
#     uci-defaults migration
#   - /etc/config/ha-cluster equals the T24 migration expected output of
#     the same case (edited file kept and migrated; the unedited shipped
#     file replaced by the new one) and holds no old-model name
#   - the ha-cluster procd instances follow the new rules, their configs
#     are generated, keepalived (left running by the upgrade) holds the
#     VIP with an unchanged config, and a restart changes nothing
#   - adding the same packages again, and running the post-upgrade script
#     again as a reinstall would, leave the config and daemons unchanged
#
# Each case runs in a throwaway node container with procd, without a
# network: veth pairs stand for the lan and backend links, so keepalived
# becomes MASTER alone. The old-package image is built from
# Containerfile.node with the old ha-cluster and luci-app-ha-cluster
# packages in place of the new ones.
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
. "$TEST_DIR/lib/cluster-utils.sh"

# ============================================
# Configuration
# ============================================

PKG_DIR="$TEST_DIR/packages"
OLD_PKG_DIR="$PKG_DIR/old"
CHAR_DIR="$TEST_DIR/characterization"
OLD_IMAGE="${OLD_IMAGE:-ha-cluster-node-old:latest}"
UPG_NODE="ha-upgrade"
MIGRATION="60_ha-cluster-sync-model"
LOG_DIR="$TEST_DIR/logs/upgrade"

# case | T24 migration case giving the expected config ("-" = the shipped
# file left as installed) | instances before | instances after
# (before, owsync without a sync peer exits at once and is respawned)
CASES="
shipped|-|-|-
old-node|02-old-node-config|keepalived owsync lease-sync|keepalived owsync lease-sync
production|13-production-node|keepalived owsync lease-sync|keepalived owsync lease-sync
sync-none|14-sync-method-none-node|keepalived lease-sync|keepalived lease-sync
vrrp-only|15-vrrp-only-peer-node|keepalived lease-sync|keepalived
"

WORK_DIR=""

# ============================================
# Helpers
# ============================================

node_sh() {
    exec_node "$UPG_NODE" sh -c "$1"
}

remove_node() {
    $CONTAINER_RUNTIME rm -f "$UPG_NODE" >/dev/null 2>&1
}

cleanup() {
    remove_node
    cleanup_temp_dir "$WORK_DIR"
}

# Running ha-cluster procd instances, space separated, "-" if none
instances() {
    node_sh '
        list=$(ubus call service list "{\"name\":\"ha-cluster\"}" 2>/dev/null)
        out=""
        for i in keepalived owsync lease-sync; do
            r=$(echo "$list" | jsonfilter -e "@[\"ha-cluster\"].instances[\"$i\"].running" 2>/dev/null)
            [ "$r" = "true" ] && out="$out $i"
        done
        echo "${out# }" | grep . || echo -'
}

# Usage: wait_instances <expected> <timeout>
wait_instances() {
    local expected="$1"
    local timeout="$2"
    local count=0

    while [ "$(instances)" != "$expected" ]; do
        [ "$count" -ge "$timeout" ] && return 1
        sleep 1
        count=$((count + 1))
    done
    return 0
}

# Instances, daemon PIDs and checksums of every generated file
state() {
    node_sh '
        echo "instances: $(ubus call service list "{\"name\":\"ha-cluster\"}" 2>/dev/null |
            jsonfilter -e "@[\"ha-cluster\"].instances[*].pid" 2>/dev/null | tr "\n" " ")"
        for f in /tmp/ha-cluster/* /tmp/dnsmasq*.d/ha-cluster.conf /etc/ha-cluster/*; do
            [ -f "$f" ] && md5sum "$f"
        done
        md5sum /etc/config/ha-cluster'
}

# State once two readings 2 s apart agree: procd reports a stopping
# instance until it exits
settled_state() {
    local count=0
    local current previous

    previous=$(state)
    while [ "$count" -lt 10 ]; do
        sleep 2
        current=$(state)
        [ "$current" = "$previous" ] && break
        previous="$current"
        count=$((count + 1))
    done
    echo "$current"
}

# Config after the first migration run, from a T24 migration expected file
t24_expected() {
    awk '
        /^== second run rc=/ { exit }
        found { print }
        /^== migration rc=/ { found = 1; getline }
    ' "$CHAR_DIR/expected/migration/$1.out"
}

# ============================================
# Setup
# ============================================

test_prerequisites() {
    subheader "Prerequisites"

    local pkg missing=""

    for pkg in ha-cluster luci-app-ha-cluster; do
        ls "$OLD_PKG_DIR/$pkg"-[0-9]*.apk >/dev/null 2>&1 || missing="$missing old/$pkg"
        ls "$PKG_DIR/$pkg"-[0-9]*.apk >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        fail "Packages missing in tests/packages:$missing (see tests/README.md, T26)"
        return 1
    fi
    if [ ! -f "$TEST_DIR/images/openwrt-x86-64-generic-rootfs.tar.gz" ]; then
        fail "OpenWrt rootfs missing in tests/images (run setup.sh first)"
        return 1
    fi
    pass "Old and new packages available"
}

# Node image with the old ha-cluster packages, built like ha-cluster-node
build_old_image() {
    subheader "Old-package node image"

    local ctx="$WORK_DIR/context"
    local pkg

    mkdir -p "$ctx/images" "$ctx/packages"
    cp "$TEST_DIR/images/openwrt-x86-64-generic-rootfs.tar.gz" "$ctx/images/"
    cp -r "$TEST_DIR/containers" "$ctx/"
    for pkg in "$PKG_DIR"/*.apk; do
        case "$(basename "$pkg")" in
            ha-cluster-[0-9]*|luci-app-ha-cluster-[0-9]*) ;;
            *) cp "$pkg" "$ctx/packages/" ;;
        esac
    done
    cp "$OLD_PKG_DIR"/ha-cluster-[0-9]*.apk "$OLD_PKG_DIR"/luci-app-ha-cluster-[0-9]*.apk \
        "$ctx/packages/"

    if ! $CONTAINER_RUNTIME build -t "$OLD_IMAGE" -f "$ctx/containers/Containerfile.node" \
            "$ctx" > "$LOG_DIR/image-build.log" 2>&1; then
        fail "Old-package image build failed (logs/upgrade/image-build.log)"
        return 1
    fi

    # Guards against new packages copied into packages/old
    if $CONTAINER_RUNTIME run --rm --entrypoint /bin/sh "$OLD_IMAGE" \
            -c "apk info -L ha-cluster" | grep -q "$MIGRATION"; then
        fail "packages/old/ha-cluster already ships the migration: not an old package"
        return 1
    fi
    pass "Image $OLD_IMAGE built with the old ha-cluster packages"
}

# Usage: start_old_node <case> <t24 case>
start_old_node() {
    local case_name="$1"
    local t24_case="$2"
    local cfg="$WORK_DIR/config"

    remove_node
    mkdir -p "$cfg"
    cp "$TEST_DIR/configs/node1/network" "$TEST_DIR/configs/node1/dhcp" "$cfg/"

    $CONTAINER_RUNTIME run -d --name "$UPG_NODE" --hostname "$UPG_NODE" \
        --privileged --network none \
        -v "$PKG_DIR:/upgrade:ro" -v "$CHAR_DIR:/char:ro" -v "$cfg:/mnt/config:ro" \
        --entrypoint /bin/sh "$OLD_IMAGE" -c '
            for link in eth0:192.168.50.10 eth1:172.30.0.10; do
                ip link add "${link%%:*}" type veth
                ip addr add "${link#*:}/24" dev "${link%%:*}"
                ip link set "${link%%:*}" up
            done
            for peer in /sys/class/net/veth*; do
                ip link set "${peer##*/}" up
            done
            exec /entrypoint.sh' >/dev/null || return 1

    wait_for "procd on $UPG_NODE" 30 "exec_node $UPG_NODE ubus list service" || return 1

    node_sh '
        uci set dhcp.@dnsmasq[0].interface=lan
        uci set dhcp.@dnsmasq[0].localservice=0
        uci set dhcp.lan.force=1
        uci commit dhcp
        mkdir -p /tmp/resolv.conf.d /tmp/dnsmasq.d
        touch /tmp/resolv.conf.d/resolv.conf.auto /tmp/dhcp.leases
        /etc/init.d/dnsmasq start' >/dev/null 2>&1
    wait_for "dnsmasq on $UPG_NODE" 15 "exec_node $UPG_NODE ubus list dnsmasq" || return 1

    if [ "$t24_case" != "-" ]; then
        node_sh "set -e; . /char/migration/cases/$t24_case.sh" || return 1
    fi

    node_sh '/etc/init.d/ha-cluster enable && /etc/init.d/ha-cluster start' \
        > "$LOG_DIR/$case_name-start.log" 2>&1
}

# ============================================
# Test Cases
# ============================================

# Usage: test_case <case> <t24 case> <instances before> <instances after>
test_case() {
    local case_name="$1"
    local t24_case="$2"
    local before="$3"
    local after="$4"
    local rc=0
    local log="$LOG_DIR/$case_name"
    local expected actual state1 state2 kpid

    subheader "Upgrade: $case_name"

    if ! start_old_node "$case_name" "$t24_case"; then
        fail "$case_name: old node did not start"
        return 1
    fi
    if wait_instances "$before" 20; then
        pass "$case_name: old packages run: $before"
    else
        fail "$case_name: old packages run '$(instances)', expected '$before'"
        rc=1
    fi
    node_sh 'cat /etc/config/ha-cluster' > "$log-before.uci"
    settled_state > "$log-state-before"
    kpid=$(node_sh 'pgrep -o keepalived')

    # The upgrade
    if node_sh 'apk add --no-network --allow-untrusted \
            /upgrade/ha-cluster-[0-9]*.apk /upgrade/luci-app-ha-cluster-[0-9]*.apk' \
            > "$log-apk.log" 2>&1; then
        pass "$case_name: apk add of the new packages succeeded"
    else
        fail "$case_name: apk add failed"
        cat "$log-apk.log"
        return 1
    fi
    if grep -q "ha-cluster-.*post-upgrade" "$log-apk.log" &&
       node_sh "apk info -L ha-cluster" | grep -q "$MIGRATION"; then
        pass "$case_name: new ha-cluster installed, post-upgrade script run"
    else
        fail "$case_name: new ha-cluster not installed as an upgrade"
        cat "$log-apk.log"
        rc=1
    fi
    if node_sh "[ ! -e /etc/uci-defaults/$MIGRATION ]"; then
        pass "$case_name: migration consumed by the upgrade"
    else
        fail "$case_name: /etc/uci-defaults/$MIGRATION left after the upgrade"
        rc=1
    fi

    # Config
    if [ "$t24_case" = "-" ]; then
        t24_expected 10-current-shipped-config > "$log-expected.uci"
    else
        t24_expected "$t24_case" > "$log-expected.uci"
    fi
    node_sh 'cat /etc/config/ha-cluster' > "$log-after.uci"
    if diff -u "$log-expected.uci" "$log-after.uci" > "$log-config.diff"; then
        pass "$case_name: config matches the T24 migration expected output"
    else
        fail "$case_name: config differs from the T24 migration expected output"
        cat "$log-config.diff"
        rc=1
    fi
    actual=$(node_sh 'uci show ha-cluster' | grep -E "=service$|\.sync_leases=|\.sync_enabled=|\.sync_method='[^o]")
    if [ -z "$actual" ]; then
        pass "$case_name: no old-model section or option left"
    else
        fail "$case_name: old-model names left: $actual"
        rc=1
    fi
    actual=$(node_sh 'ls /etc/config' | grep "^ha-cluster." || true)
    [ -n "$actual" ] && info "$case_name: apk left /etc/config/$actual (new shipped config)"

    # Daemons
    if wait_instances "$after" 20; then
        pass "$case_name: ha-cluster runs after the upgrade: $after"
    else
        fail "$case_name: ha-cluster runs '$(instances)', expected '$after'"
        rc=1
    fi
    for expected in keepalived owsync lease-sync; do
        case " $after " in
            *" $expected "*)
                node_sh "pgrep $expected >/dev/null && [ -s /tmp/ha-cluster/$expected.conf ]" ||
                    { fail "$case_name: $expected not running or its config missing"; rc=1; }
                ;;
            *)
                node_sh "! pgrep $expected >/dev/null && [ ! -e /tmp/ha-cluster/$expected.conf ]" ||
                    { fail "$case_name: $expected running or its config present"; rc=1; }
                ;;
        esac
    done
    case " $after " in
        *" keepalived "*)
            if wait_for "VIP on $UPG_NODE" 15 "node_sh 'ip addr show lan' | grep -q 192.168.50.254"; then
                pass "$case_name: keepalived holds the VIP"
            else
                fail "$case_name: VIP not held by keepalived after the upgrade"
                rc=1
            fi
            ;;
    esac
    state1=$(settled_state)
    # The upgrade start leaves keepalived running: it must not need the
    # config generated by the new code
    case " $after " in
        *" keepalived "*)
            if [ "$(grep keepalived.conf "$log-state-before")" = \
                 "$(echo "$state1" | grep keepalived.conf)" ] ||
               [ "$(node_sh 'pgrep -o keepalived')" != "$kpid" ]; then
                pass "$case_name: keepalived runs the config generated after the upgrade"
            else
                fail "$case_name: keepalived.conf changed but keepalived kept running"
                rc=1
            fi
            ;;
    esac
    node_sh '/etc/init.d/ha-cluster restart' >/dev/null 2>&1
    wait_instances "$after" 20
    state2=$(settled_state)
    # PIDs change on restart; compare the rest
    if [ "$(echo "$state1" | sed 1d)" = "$(echo "$state2" | sed 1d)" ] &&
       [ "$(instances)" = "$after" ]; then
        pass "$case_name: a restart generates the same configs and daemons"
    else
        fail "$case_name: a restart changes the upgraded state"
        echo "$state1" > "$log-state-upgrade"
        echo "$state2" > "$log-state-restart"
        diff "$log-state-upgrade" "$log-state-restart"
        rc=1
    fi

    # Same packages again: nothing to do
    state1=$(settled_state)
    node_sh 'apk add --no-network --allow-untrusted \
        /upgrade/ha-cluster-[0-9]*.apk /upgrade/luci-app-ha-cluster-[0-9]*.apk' \
        > "$log-apk-again.log" 2>&1
    state2=$(settled_state)
    if ! grep -q "Executing" "$log-apk-again.log" && [ "$state1" = "$state2" ]; then
        pass "$case_name: adding the same packages again changes nothing"
    else
        fail "$case_name: adding the same packages again changed the node"
        cat "$log-apk-again.log"
        echo "$state2" > "$log-state-again"
        echo "$state1" | diff - "$log-state-again"
        rc=1
    fi

    # Reinstall: OpenWrt's apk has no mkndx, so no repository to reinstall
    # from; restore the package's migration file and run its stored
    # post-upgrade script, as apk does on a reinstall
    node_sh "
        mkdir -p /tmp/reinstall && cd /tmp/reinstall &&
        apk extract --allow-untrusted /upgrade/ha-cluster-[0-9]*.apk &&
        cp etc/uci-defaults/$MIGRATION /etc/uci-defaults/ &&
        tar -xzOf /lib/apk/db/scripts.tar.gz \$(tar -tzf /lib/apk/db/scripts.tar.gz |
            grep '^ha-cluster-[0-9].*\.post-upgrade\$') > post-upgrade &&
        [ -s post-upgrade ] && sh post-upgrade" > "$log-reinstall.log" 2>&1
    wait_instances "$after" 20
    state2=$(settled_state)
    if [ "$(echo "$state1" | sed 1d)" = "$(echo "$state2" | sed 1d)" ] &&
       node_sh "[ ! -e /etc/uci-defaults/$MIGRATION ]" &&
       [ "$(instances)" = "$after" ]; then
        pass "$case_name: running the upgrade scripts again changes nothing"
    else
        fail "$case_name: running the upgrade scripts again changed the node"
        cat "$log-reinstall.log"
        echo "$state2" > "$log-state-reinstall"
        echo "$state1" | diff - "$log-state-reinstall"
        rc=1
    fi

    node_sh 'logread' > "$log-syslog.log" 2>&1
    remove_node
    return $rc
}

# ============================================
# Main
# ============================================

main() {
    header "T26: Package Upgrade from the Previous Model"
    info "Upgrades old ha-cluster packages with apk on old-model configs"

    local result=0
    local line case_name t24_case before after

    trap cleanup EXIT INT TERM

    test_prerequisites || return 1
    WORK_DIR=$(make_temp_dir)
    mkdir -p "$LOG_DIR"
    build_old_image || return 1

    for line in $(echo "$CASES" | tr ' ' '_'); do
        line=$(echo "$line" | tr '_' ' ')
        case_name=${line%%|*}; line=${line#*|}
        t24_case=${line%%|*}; line=${line#*|}
        before=${line%%|*}
        after=${line#*|}
        test_case "$case_name" "$t24_case" "$before" "$after" || result=1
    done

    return $result
}

main
exit $?
