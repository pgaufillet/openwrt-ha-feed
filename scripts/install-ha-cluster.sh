#!/bin/sh
#
# install-ha-cluster.sh - Install ha-cluster packages on OpenWrt
#
# Handles the dnsmasq → dnsmasq-ha replacement safely by pre-installing
# all dependencies and pre-downloading all ha_feed packages while DNS is
# still available, then performing the swap offline.
#
# Usage: sh install-ha-cluster.sh
#
# Requirements:
#   - Root access on an OpenWrt router
#   - ha_feed configured in /etc/opkg/customfeeds.conf
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

# --- Pre-flight checks ---

[ "$(id -u)" -eq 0 ] || die "This script must be run as root"
command -v opkg >/dev/null 2>&1 || die "opkg not found — is this OpenWrt?"

# Check that feed is configured
if ! grep -q 'ha_feed\|ha-feed' /etc/opkg/customfeeds.conf 2>/dev/null && \
   ! grep -q 'ha_feed\|ha-feed' /etc/opkg.conf 2>/dev/null; then
	die "ha_feed not found in opkg feeds configuration.
Add it to /etc/opkg/customfeeds.conf, e.g.:
  src/gz ha_feed https://your-server/ha-feed"
fi

# --- Step 1: Update package lists ---

info "Updating package lists..."
opkg update || die "opkg update failed — check network and feed configuration"

# --- Step 2: Check current dnsmasq status ---

STOCK_DNSMASQ=""
if opkg list-installed | grep -q '^dnsmasq-full '; then
	STOCK_DNSMASQ="dnsmasq-full"
elif opkg list-installed | grep -q '^dnsmasq '; then
	STOCK_DNSMASQ="dnsmasq"
fi

if opkg list-installed | grep -q '^dnsmasq-ha '; then
	info "dnsmasq-ha is already installed, skipping replacement"
	SKIP_DNSMASQ_SWAP=1
fi

# --- Step 3: Pre-install ALL dependencies from official feeds while DNS works ---
# After removing dnsmasq, DNS resolution dies. We must install every
# dependency that comes from official OpenWrt feeds NOW, before the swap.

info "Pre-installing dependencies from official feeds..."

# dnsmasq-ha extra deps (not in stock dnsmasq)
opkg install libnettle kmod-ipt-ipset libnetfilter-conntrack nftables-json 2>/dev/null || true

# ha-cluster deps (keepalived has many transitive deps: libnl, libipset, kmod-macvlan, etc.)
opkg install keepalived || die "Failed to install keepalived"

# lease-sync deps
opkg install libopenssl3 2>/dev/null || true

info "All dependencies installed"

# --- Step 4: Download ALL ha_feed packages locally ---
# These packages come from our custom feed, not official feeds.
# Download them now while network access works.

info "Downloading ha-cluster packages to /tmp..."
cd /tmp
opkg download dnsmasq-ha || die "Failed to download dnsmasq-ha"
opkg download ha-cluster || die "Failed to download ha-cluster"
opkg download owsync || die "Failed to download owsync"
opkg download lease-sync || die "Failed to download lease-sync"
opkg download luci-app-ha-cluster 2>/dev/null || warn "luci-app-ha-cluster not found in feeds (optional)"

info "All packages downloaded to /tmp"

# --- Step 5: Swap dnsmasq for dnsmasq-ha ---

if [ -z "$SKIP_DNSMASQ_SWAP" ] && [ -n "$STOCK_DNSMASQ" ]; then
	info "Removing $STOCK_DNSMASQ (DNS will be briefly unavailable)..."
	opkg remove "$STOCK_DNSMASQ" || {
		error "Failed to remove $STOCK_DNSMASQ"
		die "Aborted — $STOCK_DNSMASQ is still installed"
	}

	info "Installing dnsmasq-ha from local package..."
	opkg install /tmp/dnsmasq-ha_*.ipk || {
		error "dnsmasq-ha installation failed! Attempting to restore $STOCK_DNSMASQ..."
		# Try restoring from /rom overlay first, then from network
		if [ -f /rom/usr/sbin/dnsmasq ]; then
			opkg install "$STOCK_DNSMASQ" 2>/dev/null
		fi
		die "Aborted — check error messages above"
	}

	info "dnsmasq-ha installed successfully"
elif [ -z "$SKIP_DNSMASQ_SWAP" ] && [ -z "$STOCK_DNSMASQ" ]; then
	info "No stock dnsmasq detected — installing dnsmasq-ha"
	opkg install /tmp/dnsmasq-ha_*.ipk || die "Failed to install dnsmasq-ha"
fi

# --- Step 6: Install remaining packages from local .ipk files ---
# All deps are already satisfied, no network needed.

info "Installing ha-cluster packages..."
opkg install /tmp/owsync_*.ipk || die "Failed to install owsync"
opkg install /tmp/lease-sync_*.ipk || die "Failed to install lease-sync"
opkg install /tmp/ha-cluster_*.ipk || die "Failed to install ha-cluster"

if ls /tmp/luci-app-ha-cluster_*.ipk >/dev/null 2>&1; then
	info "Installing luci-app-ha-cluster..."
	opkg install /tmp/luci-app-ha-cluster_*.ipk || warn "luci-app-ha-cluster installation failed (optional)"
fi

# --- Step 7: Clean up ---

rm -f /tmp/dnsmasq-ha_*.ipk /tmp/ha-cluster_*.ipk /tmp/owsync_*.ipk \
      /tmp/lease-sync_*.ipk /tmp/luci-app-ha-cluster_*.ipk

# --- Step 8: Verify installation ---

info ""
info "=== Installation Summary ==="
INSTALLED=$(opkg list-installed 2>/dev/null | grep -E 'dnsmasq-ha|ha-cluster|owsync|lease-sync|luci-app-ha-cluster')
if [ -n "$INSTALLED" ]; then
	echo "$INSTALLED"
else
	warn "Could not verify installed packages"
fi

# Check dnsmasq is running
if pgrep -x dnsmasq >/dev/null 2>&1; then
	info "dnsmasq is running"
else
	warn "dnsmasq is not running — check: /etc/init.d/dnsmasq start"
fi

info ""
info "Installation complete. Configure ha-cluster with:"
info "  uci set ha-cluster.config.enabled='1'"
info "  uci set ha-cluster.config.encryption_key=\"\$(openssl rand -hex 32)\""
info "  # Add peers, VIPs, etc. — see ha-cluster README"
info "  uci commit ha-cluster"
