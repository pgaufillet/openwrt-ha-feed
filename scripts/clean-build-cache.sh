#!/bin/bash
# clean-build-cache.sh - Clean OpenWrt build caches for ha-feed packages
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Usage:
#   Run from OpenWrt build tree root:
#   /path/to/openwrt-ha-feed/scripts/clean-build-cache.sh [options]
#
# Options:
#   --all           Clean all HA packages (default)
#   --owsync        Clean only owsync
#   --lease-sync    Clean only lease-sync
#   --ha-cluster    Clean only ha-cluster
#   --luci          Clean only luci-app-ha-cluster
#   --dnsmasq-ha    Clean only dnsmasq-ha
#   --dry-run       Show what would be deleted without deleting
#   --help          Show this help message

set -e

# ============================================
# Configuration
# ============================================

# Package list
PACKAGES="owsync lease-sync ha-cluster luci-app-ha-cluster dnsmasq-ha"
SELECTED_PACKAGES=""
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# Functions
# ============================================

usage() {
    cat << EOF
Usage: $0 [options]

Clean OpenWrt build caches for ha-feed packages to ensure fresh builds.

This script removes cached files from three locations:
  1. dl/          - Downloaded source archives
  2. tmp/dl/      - Temporary download cache
  3. build_dir/   - Extracted and compiled sources

Options:
  --all           Clean all HA packages (default)
  --owsync        Clean only owsync
  --lease-sync    Clean only lease-sync
  --ha-cluster    Clean only ha-cluster
  --luci          Clean only luci-app-ha-cluster
  --dnsmasq-ha    Clean only dnsmasq-ha
  --dry-run       Show what would be deleted without deleting
  --help          Show this help message

Examples:
  # Clean all HA packages
  $0

  # Clean only owsync and lease-sync
  $0 --owsync --lease-sync

  # Preview what would be deleted
  $0 --dry-run

Note: Run this script from your OpenWrt build tree root directory.

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

check_openwrt_tree() {
    if [ ! -f "rules.mk" ] || [ ! -d "build_dir" ]; then
        log_error "Not in OpenWrt build tree root directory"
        log_error "Please cd to your OpenWrt build directory and run again"
        exit 1
    fi
    log_success "OpenWrt build tree detected"
}

clean_package() {
    local pkg="$1"
    local found_files=false

    echo ""
    log_info "Cleaning package: $pkg"

    # Clean dl/ directory
    if [ -n "$(find dl/ -maxdepth 1 -name "${pkg}*" 2>/dev/null)" ]; then
        found_files=true
        if [ "$DRY_RUN" = true ]; then
            log_warning "[DRY-RUN] Would delete: dl/${pkg}*"
            find dl/ -maxdepth 1 -name "${pkg}*" -exec ls -lh {} \;
        else
            log_info "Removing: dl/${pkg}*"
            find dl/ -maxdepth 1 -name "${pkg}*" -delete
            log_success "Cleaned dl/"
        fi
    fi

    # Clean tmp/dl/ directory
    if [ -d "tmp/dl" ] && [ -n "$(find tmp/dl/ -maxdepth 1 -name "${pkg}*" 2>/dev/null)" ]; then
        found_files=true
        if [ "$DRY_RUN" = true ]; then
            log_warning "[DRY-RUN] Would delete: tmp/dl/${pkg}*"
            find tmp/dl/ -maxdepth 1 -name "${pkg}*" -exec ls -lh {} \;
        else
            log_info "Removing: tmp/dl/${pkg}*"
            find tmp/dl/ -maxdepth 1 -name "${pkg}*" -delete
            log_success "Cleaned tmp/dl/"
        fi
    fi

    # Clean build_dir/ directory (more complex pattern)
    if [ -n "$(find build_dir/ -maxdepth 2 -type d -name "${pkg}-*" 2>/dev/null)" ]; then
        found_files=true
        if [ "$DRY_RUN" = true ]; then
            log_warning "[DRY-RUN] Would delete build directories:"
            find build_dir/ -maxdepth 2 -type d -name "${pkg}-*" -exec du -sh {} \;
        else
            log_info "Removing build directories: build_dir/*/${pkg}-*"
            find build_dir/ -maxdepth 2 -type d -name "${pkg}-*" -exec rm -rf {} + 2>/dev/null || true
            log_success "Cleaned build_dir/"
        fi
    fi

    if [ "$found_files" = false ]; then
        log_info "No cached files found for $pkg"
    fi
}

# ============================================
# Argument Parsing
# ============================================

if [ $# -eq 0 ]; then
    SELECTED_PACKAGES="$PACKAGES"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            SELECTED_PACKAGES="$PACKAGES"
            ;;
        --owsync)
            SELECTED_PACKAGES="$SELECTED_PACKAGES owsync"
            ;;
        --lease-sync)
            SELECTED_PACKAGES="$SELECTED_PACKAGES lease-sync"
            ;;
        --ha-cluster)
            SELECTED_PACKAGES="$SELECTED_PACKAGES ha-cluster"
            ;;
        --luci)
            SELECTED_PACKAGES="$SELECTED_PACKAGES luci-app-ha-cluster"
            ;;
        --dnsmasq-ha)
            SELECTED_PACKAGES="$SELECTED_PACKAGES dnsmasq-ha"
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

# Default to all packages if none selected
if [ -z "$SELECTED_PACKAGES" ]; then
    SELECTED_PACKAGES="$PACKAGES"
fi

# ============================================
# Main
# ============================================

echo "============================================"
echo "OpenWrt HA-Feed Cache Cleaner"
echo "============================================"

check_openwrt_tree

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY-RUN MODE: No files will be deleted"
fi

echo ""
log_info "Packages to clean: $SELECTED_PACKAGES"

for pkg in $SELECTED_PACKAGES; do
    clean_package "$pkg"
done

echo ""
echo "============================================"
if [ "$DRY_RUN" = true ]; then
    log_info "Dry-run complete. Run without --dry-run to actually delete files."
else
    log_success "Cache cleanup complete!"
    echo ""
    log_info "Next steps:"
    echo "  1. Update feeds: ./scripts/feeds update ha_feed"
    echo "  2. Rebuild packages: make package/<package-name>/compile V=s"
fi
echo "============================================"
