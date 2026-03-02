#!/bin/sh
# teardown.sh - Stop and clean up HA cluster test environment
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Usage:
#   ./teardown.sh                   # Stop containers, keep data
#   ./teardown.sh --clean           # Stop containers, remove data
#   ./teardown.sh --full            # Remove everything including images

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

# Load common utilities
. "$TEST_DIR/lib/common.sh"

# ============================================
# Configuration
# ============================================

CLEAN_DATA=false
FULL_CLEAN=false

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --clean|-c)
            CLEAN_DATA=true
            ;;
        --full|-f)
            FULL_CLEAN=true
            CLEAN_DATA=true
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --clean, -c   Also remove data and logs directories"
            echo "  --full, -f    Remove everything including images and packages"
            echo "  --help, -h    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# ============================================
# Cleanup Functions
# ============================================

stop_containers() {
    header "Stopping Containers"

    check_runtime || exit 1

    # Detect compose command
    # Prefer podman-compose for podman (native, no socket required)
    if [ "$CONTAINER_RUNTIME" = "podman" ] && command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_CMD="podman-compose"
    elif $CONTAINER_RUNTIME compose version >/dev/null 2>&1; then
        COMPOSE_CMD="$CONTAINER_RUNTIME compose"
    else
        COMPOSE_CMD="docker-compose"
    fi

    cd "$TEST_DIR/compose"

    info "Stopping containers..."
    $COMPOSE_CMD down 2>/dev/null || true

    # Also try to stop any orphan containers
    for container in ha-node1 ha-node2 ha-node3 ha-client1 ha-client2; do
        if $CONTAINER_RUNTIME ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            info "Removing orphan container: $container"
            $CONTAINER_RUNTIME rm -f "$container" 2>/dev/null || true
        fi
    done

    info "Containers stopped"
}

remove_networks() {
    header "Removing Networks"

    for network in ha-backend ha-client; do
        if $CONTAINER_RUNTIME network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            info "Removing network: $network"
            $CONTAINER_RUNTIME network rm "$network" 2>/dev/null || true
        fi
    done

    # Also try compose network names
    for network in compose_ha-backend compose_ha-client tests_ha-backend tests_ha-client; do
        if $CONTAINER_RUNTIME network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            info "Removing network: $network"
            $CONTAINER_RUNTIME network rm "$network" 2>/dev/null || true
        fi
    done

    info "Networks removed"
}

clean_data() {
    header "Cleaning Data Directories"

    if [ -d "$TEST_DIR/data" ]; then
        info "Removing data directory..."
        rm -rf "$TEST_DIR/data"
    fi

    if [ -d "$TEST_DIR/logs" ]; then
        info "Removing logs directory..."
        rm -rf "$TEST_DIR/logs"
    fi

    info "Data cleaned"
}

remove_images() {
    header "Removing Container Images"

    for image in ha-cluster-node:latest ha-dhcp-client:latest; do
        if $CONTAINER_RUNTIME images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
            info "Removing image: $image"
            $CONTAINER_RUNTIME rmi "$image" 2>/dev/null || true
        fi
    done

    info "Images removed"
}

clean_artifacts() {
    header "Cleaning Build Artifacts"

    if [ -d "$TEST_DIR/images" ]; then
        info "Removing rootfs images..."
        rm -rf "$TEST_DIR/images"
    fi

    if [ -d "$TEST_DIR/packages" ]; then
        info "Removing packages..."
        rm -rf "$TEST_DIR/packages"
    fi

    # Remove any build logs
    rm -f "$TEST_DIR"/*.log

    info "Artifacts cleaned"
}

# ============================================
# Main
# ============================================

main() {
    echo "========================================="
    echo "HA Cluster Test Teardown"
    echo "========================================="

    stop_containers
    remove_networks

    if [ "$CLEAN_DATA" = "true" ]; then
        clean_data
    fi

    if [ "$FULL_CLEAN" = "true" ]; then
        remove_images
        clean_artifacts
    fi

    echo ""
    echo "========================================="
    echo "Teardown Complete"
    echo "========================================="
    echo ""

    if [ "$FULL_CLEAN" = "true" ]; then
        echo "All resources removed (full clean)"
    elif [ "$CLEAN_DATA" = "true" ]; then
        echo "Containers stopped, data removed"
        echo "Images preserved for faster restart"
    else
        echo "Containers stopped, data preserved"
        echo "Restart with: $TEST_DIR/scripts/setup.sh --skip-build"
    fi
}

main
