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
# Environment variables:
#   JOBS       Parallel build jobs (default: number of CPUs).
#   SIGN_KEY   Path (inside the container) to a usign private key. When set, a
#              signed package index is generated. Mount it read-only, e.g.
#              -v "$PWD/keys/ha_feed.sec:/keys/ha_feed.sec:ro" -e SIGN_KEY=/keys/ha_feed.sec
#   VERBOSE    Set to 1 for `make ... V=s` verbose output.

set -euo pipefail

SDK_DIR="/home/build/openwrt-sdk"
OUTPUT_DIR="/output"
DEFAULT_PACKAGES=(dnsmasq-ha owsync lease-sync ha-cluster luci-app-ha-cluster)

JOBS="${JOBS:-$(nproc)}"
V_FLAG=""
[ "${VERBOSE:-0}" = "1" ] && V_FLAG="V=s"

cd "$SDK_DIR"

if [ "$#" -gt 0 ]; then
    PACKAGES=("$@")
else
    PACKAGES=("${DEFAULT_PACKAGES[@]}")
fi

echo "=============================================="
echo " OpenWrt HA Cluster feed - package build"
echo "=============================================="
echo " SDK:      $SDK_DIR"
echo " Packages: ${PACKAGES[*]}"
echo " Jobs:     $JOBS"
echo "=============================================="

echo "[1/4] Updating feeds..."
./scripts/feeds update -a

echo "[2/4] Installing feed packages..."
for pkg in "${PACKAGES[@]}"; do
    ./scripts/feeds install "$pkg"
done

echo "[3/4] Configuring and compiling packages in parallel..."
# The SDK defaults to CONFIG_ALL=y, which selects every package of every
# source pulled in by "feeds install", optional dependencies included.
# Select only the requested packages and what they depend on.
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
# Compile all in parallel
make "package/compile" -j"$JOBS" $V_FLAG

echo "[4/4] Collecting artifacts..."
# OpenWrt >= 24.10 emits .apk; older releases emit .ipk. Handle both.
mapfile -t artifacts < <(find bin/packages -type f \( -name '*.apk' -o -name '*.ipk' \) 2>/dev/null)

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
    make package/index BUILD_KEY="$SIGN_KEY"
fi

if [ -d "$OUTPUT_DIR" ]; then
    # Preserve the bin/packages/<arch>/ha_feed/ layout under /output.
    if (cd bin/packages && find . -type f \
            \( -name '*.apk' -o -name '*.ipk' -o -name 'Packages*' -o -name 'index.json' \) \
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
