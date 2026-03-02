#!/bin/bash
# setup-openwrt-buildroot.sh - Set up an OpenWrt buildroot for ha-feed development
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Clones the OpenWrt repository at a given release tag and configures it
# to build the ha-cluster feed packages.
#
# Usage:
#   ./setup-openwrt-buildroot.sh [options] <target-directory>
#
# Options:
#   --tag <tag>     OpenWrt release tag (default: v24.10.5)
#   --config <file> Build config file to apply (default: configs/config-ha-x86_64)
#   --no-config     Skip config step entirely
#   --help          Show this help message

set -e

# ============================================
# Configuration
# ============================================

DEFAULT_TAG="v24.10.5"
OPENWRT_REPO="https://github.com/openwrt/openwrt.git"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FEED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_CONFIG="$FEED_DIR/configs/config-ha-x86_64"

TAG="$DEFAULT_TAG"
CONFIG_FILE="__default__"
TARGET_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
# Functions
# ============================================

usage() {
    cat << EOF
Usage: $0 [options] <target-directory>

Set up an OpenWrt buildroot for building ha-cluster feed packages.

This script:
  1. Clones the OpenWrt repository at the specified release tag
  2. Configures feeds.conf with pinned upstream feeds + local ha_feed
  3. Runs feeds update and install
  4. Applies the bundled build config (or a custom one via --config)

Arguments:
  <target-directory>    Where to clone OpenWrt (e.g. ../openwrt)

Options:
  --tag <tag>           OpenWrt release tag (default: $DEFAULT_TAG)
  --config <file>       Build config file to apply (default: configs/config-ha-x86_64)
  --no-config           Skip config step entirely
  --help                Show this help message

Examples:
  # Default setup (v24.10.5 + bundled x86_64 config) in sibling directory
  $0 ../openwrt

  # Custom config file
  $0 --config my-config ../openwrt

  # Set up a second buildroot for a different version
  $0 --tag v25.12.0 --no-config ../openwrt-25.12

EOF
    exit 0
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# Argument Parsing
# ============================================

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            TAG="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --no-config)
            CONFIG_FILE=""
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            if [ -n "$TARGET_DIR" ]; then
                log_error "Unexpected argument: $1"
                exit 1
            fi
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

if [ -z "$TARGET_DIR" ]; then
    log_error "Target directory is required"
    echo "Use --help for usage information"
    exit 1
fi

# Resolve to absolute path
TARGET_DIR="$(cd "$(dirname "$TARGET_DIR")" 2>/dev/null && pwd)/$(basename "$TARGET_DIR")"

# Resolve default config
if [ "$CONFIG_FILE" = "__default__" ]; then
    if [ -f "$DEFAULT_CONFIG" ]; then
        CONFIG_FILE="$DEFAULT_CONFIG"
    else
        log_warning "Default config not found: $DEFAULT_CONFIG"
        CONFIG_FILE=""
    fi
elif [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# ============================================
# Main
# ============================================

echo "============================================"
echo "OpenWrt Buildroot Setup"
echo "============================================"
echo ""
log_info "Tag:        $TAG"
log_info "Target:     $TARGET_DIR"
log_info "Feed:       $FEED_DIR"
if [ -n "$CONFIG_FILE" ]; then
    log_info "Config:     $CONFIG_FILE"
else
    log_info "Config:     (none)"
fi
echo ""

# Step 1: Clone
if [ -d "$TARGET_DIR" ]; then
    log_error "Target directory already exists: $TARGET_DIR"
    log_error "Remove it first or choose a different path"
    exit 1
fi

log_info "Cloning OpenWrt at tag $TAG..."
git clone --branch "$TAG" --depth 1 "$OPENWRT_REPO" "$TARGET_DIR"
log_success "Clone complete"

# Step 2: Configure feeds
log_info "Configuring feeds.conf..."
cp "$TARGET_DIR/feeds.conf.default" "$TARGET_DIR/feeds.conf"
echo "src-link ha_feed $FEED_DIR" >> "$TARGET_DIR/feeds.conf"
log_success "feeds.conf configured (upstream feeds + ha_feed src-link)"

# Step 3: Update and install feeds
log_info "Updating feeds..."
cd "$TARGET_DIR"
./scripts/feeds update -a
log_success "Feeds updated"

log_info "Installing feeds..."
./scripts/feeds install -a
log_success "Feeds installed"

# Step 4: Apply config
if [ -n "$CONFIG_FILE" ]; then
    log_info "Applying build config from $CONFIG_FILE..."
    cp "$CONFIG_FILE" "$TARGET_DIR/.config"
    make defconfig
    log_success "Config applied"
else
    log_warning "No config file provided — run 'make menuconfig' to configure"
fi

# Done
echo ""
echo "============================================"
log_success "OpenWrt buildroot ready at: $TARGET_DIR"
echo ""
log_info "Next steps:"
echo "  cd $TARGET_DIR"
if [ -z "$CONFIG_FILE" ]; then
    echo "  make menuconfig              # Configure build"
fi
echo "  make package/ha-cluster/compile V=s"
echo "  make package/owsync/compile V=s"
echo "  make package/lease-sync/compile V=s"
echo "  make package/dnsmasq-ha/compile V=s"
echo "  make package/luci-app-ha-cluster/compile V=s"
echo ""
echo "  Built packages: bin/packages/*/ha_feed/"
echo "============================================"
