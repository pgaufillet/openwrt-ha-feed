#!/bin/sh
#
# install-ha-cluster.sh - Install ha-cluster packages on OpenWrt
#
# Handles the dnsmasq → dnsmasq-ha replacement safely by pre-installing
# all dependencies and pre-downloading all ha_feed packages while DNS is
# still available, then performing the swap offline.
#
# Usage: sh install-ha-cluster.sh [--force-reinstall]
#
# Options:
#   --force-reinstall  Reinstall all ha_feed packages even if already installed.
#                      Useful after rebuilding packages with the same version.
#
# Requirements:
#   - Root access on an OpenWrt router
#   - ha_feed configured in apk repositories
#   - Network connectivity (for package download)

set -e

# Colors for output (if terminal supports them)
if [ -t 1 ]; then
	GREEN='\033[0;32m'
	RED='\033[0;31m'
	YELLOW='\033[1;33m'
	NC='\033[0m'
else
	GREEN=''
	RED=''
	YELLOW=''
	NC=''
fi

info() {
	printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

warn() {
	printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

error() {
	printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

die() {
	error "$1"
	exit 1
}

# --- Parse arguments ---

FORCE_REINSTALL=""
for arg in "$@"; do
	case "$arg" in
		--force-reinstall) FORCE_REINSTALL=1 ;;
		-h|--help)
			sed -n '2,/^$/s/^# \?//p' "$0"
			exit 0
			;;
		*) die "Unknown option: $arg" ;;
	esac
done

# --- Pre-flight checks ---

[ "$(id -u)" -eq 0 ] || die "This script must be run as root"
command -v apk >/dev/null 2>&1 || die "apk not found — is this OpenWrt 25.12+?"

# --- Step 1: Update package lists ---

info "Updating package lists..."
apk update || warn "apk update returned non-zero (some repositories may be unreachable)"

# Verify ha_feed packages are available
if ! apk search dnsmasq-ha 2>/dev/null | grep -q dnsmasq-ha; then
	die "dnsmasq-ha not found in repositories — check that ha_feed is configured"
fi

# --- Step 2: Check current dnsmasq status ---

STOCK_DNSMASQ=""
if apk info -e dnsmasq-full 2>/dev/null; then
	STOCK_DNSMASQ="dnsmasq-full"
elif apk info -e dnsmasq 2>/dev/null; then
	STOCK_DNSMASQ="dnsmasq"
fi

SKIP_DNSMASQ_SWAP=""
if apk info -e dnsmasq-ha 2>/dev/null; then
	if [ -n "$FORCE_REINSTALL" ]; then
		info "dnsmasq-ha is already installed (will force-reinstall)"
	else
		info "dnsmasq-ha is already installed, skipping replacement"
		SKIP_DNSMASQ_SWAP=1
	fi
fi

# --- Step 3: Pre-install ALL dependencies from official feeds while DNS works ---
# After removing dnsmasq, DNS resolution dies. We must install every
# dependency that comes from official OpenWrt feeds NOW, before the swap.

info "Pre-installing dependencies from official feeds..."

# dnsmasq-ha extra deps (not in stock dnsmasq)
apk add libnettle kmod-ipt-ipset libnetfilter-conntrack nftables-json 2>/dev/null || true

# ha-cluster deps (keepalived has many transitive deps: libnl, libipset, kmod-macvlan, etc.)
apk add keepalived || die "Failed to install keepalived"

# lease-sync deps
apk add libopenssl3 2>/dev/null || true

info "All dependencies installed"

# --- Step 4: Download ALL ha_feed packages locally ---
# These packages come from our custom feed, not official feeds.
# Download them now while network access works.

info "Downloading ha-cluster packages to /tmp..."
cd /tmp
apk fetch dnsmasq-ha || die "Failed to download dnsmasq-ha"
apk fetch ha-cluster || die "Failed to download ha-cluster"
apk fetch owsync || die "Failed to download owsync"
apk fetch lease-sync || die "Failed to download lease-sync"
apk fetch luci-app-ha-cluster 2>/dev/null || warn "luci-app-ha-cluster not found in feeds (optional)"

info "All packages downloaded to /tmp"

# --- Step 5: Swap dnsmasq for dnsmasq-ha ---

if [ -z "$SKIP_DNSMASQ_SWAP" ] && [ -n "$STOCK_DNSMASQ" ]; then
	info "Removing $STOCK_DNSMASQ (DNS will be briefly unavailable)..."
	apk del "$STOCK_DNSMASQ" || {
		error "Failed to remove $STOCK_DNSMASQ"
		die "Aborted — $STOCK_DNSMASQ is still installed"
	}

	info "Installing dnsmasq-ha from local package..."
	apk add --allow-untrusted /tmp/dnsmasq-ha-*.apk || {
		error "dnsmasq-ha installation failed! Attempting to restore $STOCK_DNSMASQ..."
		apk add "$STOCK_DNSMASQ" 2>/dev/null || true
		die "Aborted — check error messages above"
	}

	info "dnsmasq-ha installed successfully"
elif [ -z "$SKIP_DNSMASQ_SWAP" ] && [ -z "$STOCK_DNSMASQ" ]; then
	info "No stock dnsmasq detected — installing dnsmasq-ha"
	apk add --allow-untrusted /tmp/dnsmasq-ha-*.apk || die "Failed to install dnsmasq-ha"
fi

# --- Step 6: Install remaining packages from local .apk files ---
# All deps are already satisfied, no network needed.

info "Installing ha-cluster packages..."
apk add --allow-untrusted /tmp/owsync-*.apk || die "Failed to install owsync"
apk add --allow-untrusted /tmp/lease-sync-*.apk || die "Failed to install lease-sync"
apk add --allow-untrusted /tmp/ha-cluster-*.apk || die "Failed to install ha-cluster"

if ls /tmp/luci-app-ha-cluster-*.apk >/dev/null 2>&1; then
	info "Installing luci-app-ha-cluster..."
	apk add --allow-untrusted /tmp/luci-app-ha-cluster-*.apk || warn "luci-app-ha-cluster installation failed (optional)"
fi

# --- Step 7: Clean up ---

rm -f /tmp/dnsmasq-ha-*.apk /tmp/ha-cluster-*.apk /tmp/owsync-*.apk \
      /tmp/lease-sync-*.apk /tmp/luci-app-ha-cluster-*.apk

# --- Step 8: Verify installation ---

info ""
info "=== Installation Summary ==="
for pkg in dnsmasq-ha ha-cluster owsync lease-sync luci-app-ha-cluster; do
	if apk info -e "$pkg" 2>/dev/null; then
		ver=$(apk info "$pkg" 2>/dev/null | head -1)
		info "  $ver"
	fi
done

# Check dnsmasq is running
if pgrep -x dnsmasq >/dev/null 2>&1; then
	info "dnsmasq is running"
else
	warn "dnsmasq is not running — check: /etc/init.d/dnsmasq start"
fi

info ""
info "Installation complete. Configure ha-cluster with:"
info "  uci set ha-cluster.config.enabled='1'"
info "  uci set ha-cluster.config.encryption_key=\"\$(hexdump -n 32 -v -e '1/1 \"%02x\"' /dev/urandom)\""
info "  # Add peers, VIPs, etc. — see ha-cluster README"
info "  uci commit ha-cluster"
