#!/bin/bash
# build-packages.sh - Compile the ha-cluster feed packages inside the SDK image.
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Runs as the container entrypoint from /home/build/openwrt-sdk.
#
# Usage (from the host):
#   docker run --rm -v "$PWD/output:/output" ha-feed-build [PKG ...]
#
# With no package arguments, all five feed packages are built. Pass a subset to
# build only those, e.g.:
#   docker run --rm -v "$PWD/output:/output" ha-feed-build owsync lease-sync
#
# To keep the SDK state (downloads, build and staging directories) between
# runs, so that later runs only rebuild the requested packages and what
# changed, mount a named volume on the SDK directory; it is seeded from the
# image on first use:
#   docker run --rm -v ha-feed-sdk:/home/build/openwrt-sdk \
#     -v "$PWD/output:/output" ha-feed-build [PKG ...]
#
# Environment variables:
#   JOBS       Parallel build jobs (default: number of CPUs).
#   SIGN_KEY   Path (inside the container) to the index signing key: an apk
#              ECDSA private key on 25.12 and later, a usign key on 24.10
#              and earlier. When set, a signed package index is generated.
#              Mount it read-only, e.g. -v "$PWD/keys/ha_feed_apk.sec:/keys/ha_feed_apk.sec:ro"
#              -e SIGN_KEY=/keys/ha_feed_apk.sec
#   VERBOSE    Set to 1 for `make ... V=s` verbose output.

set -euo pipefail

SDK_DIR="/home/build/openwrt-sdk"
OUTPUT_DIR="/output"
DEFAULT_PACKAGES=(dnsmasq-ha owsync lease-sync ha-cluster luci-app-ha-cluster)

JOBS="${JOBS:-$(nproc)}"
V_FLAG=""
[ "${VERBOSE:-0}" = "1" ] && V_FLAG="V=s"

cd "$SDK_DIR"

# A volume mounted on the SDK directory keeps its state between runs.
CACHED=0
mountpoint -q "$SDK_DIR" && CACHED=1

if [ ! -f Makefile ]; then
    echo "ERROR: $SDK_DIR is empty. Mount a named volume there, not a host" >&2
    echo "directory: only named volumes are seeded from the image." >&2
    exit 1
fi
if ! cmp -s /home/build/.image-id .image-id; then
    echo "ERROR: the volume mounted on $SDK_DIR was seeded from another image." >&2
    echo "Remove it (docker volume rm <name>) and run again." >&2
    exit 1
fi
exec 9> .build.lock
if ! flock -n 9; then
    echo "ERROR: another build is using this SDK volume." >&2
    exit 1
fi

if [ "$#" -gt 0 ]; then
    PACKAGES=("$@")
else
    PACKAGES=("${DEFAULT_PACKAGES[@]}")
fi

echo "=============================================="
echo " OpenWrt HA Cluster feed - package build"
echo "=============================================="
echo " SDK:      $SDK_DIR$([ "$CACHED" = 0 ] || echo " (volume)")"
echo " Packages: ${PACKAGES[*]}"
echo " Jobs:     $JOBS"
echo "=============================================="

echo "[1/4] Updating feeds..."
# The upstream feeds are fetched at image build time; update ha_feed, plus
# any feed not fetched yet.
feeds=()
while read -r name; do
    if [ "$name" = ha_feed ] || [ ! -f "feeds/$name.index" ]; then
        feeds+=("$name")
    fi
done < <(awk '/^src-/ { for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; break } }' feeds.conf)
./scripts/feeds update "${feeds[@]}"

echo "[2/4] Installing feed packages..."
# Start from a clean slate so that dependency changes in the feed are
# picked up when the SDK directory is reused.
./scripts/feeds uninstall -a > /dev/null
for pkg in "${PACKAGES[@]}"; do
    ./scripts/feeds install "$pkg"
done

echo "[3/4] Configuring and compiling packages in parallel..."
# The SDK defaults to CONFIG_ALL=y, which selects every package of every
# source pulled in by "feeds install", optional dependencies included.
# Select only the requested packages and what they depend on.
[ ! -f .config ] || cp -p .config .config.prev
{
    echo "# CONFIG_ALL is not set"
    echo "# CONFIG_ALL_KMODS is not set"
    echo "# CONFIG_ALL_NONSHARED is not set"
    for pkg in "${PACKAGES[@]}"; do
        echo "CONFIG_PACKAGE_$pkg=m"
    done
} > .config
# Expand the minimal package selection into a full .config.
make defconfig
# Keep the previous mtime when the SDK directory is reused and the
# configuration did not change, so the build stamps stay valid.
if [ -f .config.prev ]; then
    if cmp -s .config .config.prev; then
        touch -r .config.prev .config
    fi
    rm -f .config.prev
fi
# OpenWrt >= 24.10 emits .apk; older releases emit .ipk. Handle both.
# A reused SDK also holds the packages of earlier runs: only the requested
# ones are collected, after dropping their previous artifacts so that make
# rebuilds them. Removing any other artifact would make it rebuild that
# package from scratch too.
if [ "$CACHED" = 0 ]; then
    match=(-name '*.apk' -o -name '*.ipk')
else
    match=()
    for pkg in "${PACKAGES[@]}"; do
        match+=(-o -name "$pkg-[0-9]*.apk" -o -name "${pkg}_[0-9]*.ipk")
    done
    match=("${match[@]:1}")
    find bin/packages -type f \( "${match[@]}" \) -delete 2>/dev/null || true
fi
# Compile all in parallel
make "package/compile" -j"$JOBS" $V_FLAG
# The kernel module packages leave their packaging files in their build
# directory, newer than its build stamp: kept, they would make the next run
# repackage all the modules of the target, which takes minutes.
[ "$CACHED" = 0 ] || rm -rf build_dir/target-*/linux-*/packages/apk-*

echo "[4/4] Collecting artifacts..."
mapfile -t artifacts < <(find bin/packages -type f \( "${match[@]}" \) 2>/dev/null)

if [ "${#artifacts[@]}" -eq 0 ]; then
    echo "ERROR: no package artifacts were produced." >&2
    exit 1
fi

if [ -n "${SIGN_KEY:-}" ]; then
    if [ ! -f "$SIGN_KEY" ]; then
        echo "ERROR: SIGN_KEY=$SIGN_KEY not found (did you mount it?)." >&2
        exit 1
    fi
    echo "  Signing package index with $SIGN_KEY..."
    make package/index BUILD_KEY="$SIGN_KEY" BUILD_KEY_APK_SEC="$SIGN_KEY"
fi

if [ -d "$OUTPUT_DIR" ]; then
    # Preserve the bin/packages/<arch>/ha_feed/ layout under /output.
    if (cd bin/packages && find . -type f \
            \( "${match[@]}" -o -name 'Packages*' -o -name 'packages.adb' \
               -o -name 'index.json' \) \
            -exec cp --parents -t "$OUTPUT_DIR" {} +); then
        echo "  Copied artifacts to $OUTPUT_DIR"
    else
        cat >&2 <<'EOF'
ERROR: packages built successfully but could not be written to /output.
This is almost always a user-namespace mapping issue with rootless Podman:
the in-container build user does not map to the owner of the mounted host
directory. Re-run adding one of:

  docker/podman run --userns=keep-id -v "$PWD/output:/output" ...
  podman run -v "$PWD/output:/output:U" ...

(Plain Docker works without extra flags when the host directory is writable
by UID 1000.)
EOF
        exit 1
    fi
else
    echo "  NOTE: /output is not mounted; artifacts remain inside the container."
fi

echo "=============================================="
echo " Done. Built ${#artifacts[@]} package file(s):"
for a in "${artifacts[@]}"; do
    echo "   - ${a#bin/packages/}"
done
echo "=============================================="
