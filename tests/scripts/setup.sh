#!/bin/sh
# setup.sh - Build container images and start HA cluster test environment
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Usage:
#   ./setup.sh                     # Build and start 2-node cluster
#   ./setup.sh --3node             # Build and start 3-node cluster
#   ./setup.sh --build-only        # Only build images, don't start
#   ./setup.sh --skip-build        # Skip image build, just start containers

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"

# Load common utilities
. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

# ============================================
# Configuration
# ============================================

THREE_NODE=false
BUILD_ONLY=false
SKIP_BUILD=false
FORCE_REBUILD=false

# OpenWrt rootfs URL (update version as needed)
OPENWRT_VERSION="24.10.5"
OPENWRT_ROOTFS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/openwrt-${OPENWRT_VERSION}-x86-64-rootfs.tar.gz"
OPENWRT_ROOTFS_FILE="openwrt-x86-64-generic-rootfs.tar.gz"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --3node)
            THREE_NODE=true
            ;;
        --build-only)
            BUILD_ONLY=true
            ;;
        --skip-build)
            SKIP_BUILD=true
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --3node         Start 3-node cluster instead of 2-node"
            echo "  --build-only    Only build images, don't start containers"
            echo "  --skip-build    Skip image build, just start containers"
            echo "  --force-rebuild Force rebuild of images even if they exist"
            echo "  --help, -h      Show this help message"
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
# Helper Functions
# ============================================

check_prerequisites() {
    header "Checking Prerequisites"

    check_runtime || exit 1
    info "Container runtime: $CONTAINER_RUNTIME"

    # Check for compose support
    # Prefer podman-compose for podman (native, no socket required)
    # Then try $RUNTIME compose, then standalone docker-compose
    if [ "$CONTAINER_RUNTIME" = "podman" ] && command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_CMD="podman-compose"
    elif $CONTAINER_RUNTIME compose version >/dev/null 2>&1; then
        COMPOSE_CMD="$CONTAINER_RUNTIME compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        echo "Error: No compose tool found (podman-compose, '$CONTAINER_RUNTIME compose', or docker-compose)"
        exit 1
    fi
    info "Compose command: $COMPOSE_CMD"

    # Check if running as root or with proper permissions
    if ! $CONTAINER_RUNTIME info >/dev/null 2>&1; then
        echo "Error: Cannot connect to container runtime. Check permissions."
        exit 1
    fi
    info "Container runtime accessible"
}

ensure_rootfs() {
    header "Ensuring OpenWrt Rootfs"

    local rootfs_path="$TEST_DIR/images/$OPENWRT_ROOTFS_FILE"

    if [ -f "$rootfs_path" ]; then
        info "Rootfs exists: $rootfs_path"
        return 0
    fi

    info "Downloading OpenWrt rootfs..."
    info "URL: $OPENWRT_ROOTFS_URL"

    mkdir -p "$TEST_DIR/images"

    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$rootfs_path" "$OPENWRT_ROOTFS_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$rootfs_path" "$OPENWRT_ROOTFS_URL"
    else
        echo "Error: Neither curl nor wget found. Please install one."
        exit 1
    fi

    info "Rootfs downloaded: $rootfs_path"
}

ensure_packages() {
    header "Ensuring HA Packages"

    local pkg_dir="$TEST_DIR/packages"
    mkdir -p "$pkg_dir"

    # Check if packages exist
    if ls "$pkg_dir"/*.ipk >/dev/null 2>&1; then
        info "Using packages from $pkg_dir"
        ls -la "$pkg_dir"/*.ipk
        return 0
    fi

    echo ""
    echo "========================================="
    echo "Packages Not Found"
    echo "========================================="
    echo ""
    echo "No pre-built packages found. You have two options:"
    echo ""
    echo "1. Build packages using OpenWrt SDK:"
    echo "   cd /home/pgaufillet/git/ha-cluster/openwrt"
    echo "   make package/ha-cluster/compile V=s"
    echo "   make package/owsync/compile V=s"
    echo "   make package/lease-sync/compile V=s"
    echo "   make package/dnsmasq-ha/compile V=s"
    echo "   make package/luci-app-ha-cluster/compile V=s"
    echo ""
    echo "2. Copy pre-built packages to:"
    echo "   $pkg_dir/"
    echo ""
    echo "Required packages:"
    echo "   - dnsmasq-ha_*.ipk"
    echo "   - lease-sync_*.ipk"
    echo "   - owsync_*.ipk"
    echo "   - ha-cluster_*.ipk"
    echo "   - luci-app-ha-cluster_*.ipk"
    echo ""
    exit 1
}

build_images() {
    header "Building Container Images"

    cd "$TEST_DIR"

    # Determine cache option
    local cache_opt=""
    if [ "$FORCE_REBUILD" = "true" ]; then
        cache_opt="--no-cache"
        info "Force rebuild: disabling layer cache"
    fi

    # Build node image
    info "Building ha-cluster-node image..."
    $CONTAINER_RUNTIME build $cache_opt \
        -t ha-cluster-node:latest \
        -f containers/Containerfile.node \
        .

    # Build DHCP client image
    info "Building ha-dhcp-client image..."
    $CONTAINER_RUNTIME build $cache_opt \
        -t ha-dhcp-client:latest \
        -f containers/Containerfile.dhcp-client \
        containers/

    info "Images built successfully"
    $CONTAINER_RUNTIME images | grep -E "ha-cluster-node|ha-dhcp-client"
}

start_cluster() {
    header "Starting HA Cluster"

    cd "$TEST_DIR/compose"

    # Create data and log directories
    mkdir -p "$TEST_DIR/data/node1" "$TEST_DIR/data/node2" "$TEST_DIR/logs/node1" "$TEST_DIR/logs/node2"
    if [ "$THREE_NODE" = "true" ]; then
        mkdir -p "$TEST_DIR/data/node3" "$TEST_DIR/logs/node3"
    fi

    # Stop any existing containers
    info "Stopping existing containers..."
    $COMPOSE_CMD down 2>/dev/null || true

    # Start cluster
    if [ "$THREE_NODE" = "true" ]; then
        info "Starting 3-node cluster..."
        $COMPOSE_CMD -f docker-compose.yml -f docker-compose.3node.yml up -d
    else
        info "Starting 2-node cluster..."
        $COMPOSE_CMD up -d
    fi

    info "Waiting for containers to start..."
    sleep 5

    # Check container status
    info "Container status:"
    $COMPOSE_CMD ps
}

configure_nodes() {
    header "Configuring Nodes"

    for node in ha-node1 ha-node2; do
        info "Configuring $node..."

        # Wait for container to be ready
        if ! wait_for "container $node" 30 "$CONTAINER_RUNTIME exec $node echo ready"; then
            echo "Error: Container $node not ready"
            exit 1
        fi

        # Apply HA cluster configuration
        local config_file
        case "$node" in
            ha-node1) config_file="$TEST_DIR/configs/node1/ha-cluster" ;;
            ha-node2) config_file="$TEST_DIR/configs/node2/ha-cluster" ;;
        esac

        # The config is mounted, so just need to apply it
        # For now, configure via uci directly from environment variables
        configure_node_from_env "$node"
    done

    if [ "$THREE_NODE" = "true" ]; then
        info "Configuring ha-node3..."
        configure_node_from_env "ha-node3"
    fi

    info "Configuration complete"
}

apply_ipv6_workaround() {
    header "Checking IPv6 Addresses"

    local needs_workaround=false
    local nodes="ha-node1 ha-node2"
    [ "$THREE_NODE" = "true" ] && nodes="$nodes ha-node3"

    # Check if any node is missing IPv6 addresses
    for node in $nodes; do
        local has_ipv6=0
        if $CONTAINER_RUNTIME exec "$node" ip -6 addr show scope global 2>/dev/null | grep -q "fd00:"; then
            has_ipv6=1
        fi

        if [ "$has_ipv6" -eq 0 ]; then
            needs_workaround=true
            break
        fi
    done

    if [ "$needs_workaround" = "false" ]; then
        info "IPv6 addresses present on all nodes"
        return 0
    fi

    echo ""
    echo "========================================="
    echo "IPv6 Workaround Required"
    echo "========================================="
    echo ""
    echo "Podman/netavark did not assign IPv6 addresses to container interfaces."
    echo "Applying workaround: manually adding IPv6 addresses..."
    echo ""

    # Apply workaround for each node
    for node in $nodes; do
        # Get IPv6 addresses from environment
        local backend_ip6 client_ip6

        case "$node" in
            ha-node1)
                backend_ip6="fd00:172:30::10"
                client_ip6="fd00:192:168:50::10"
                ;;
            ha-node2)
                backend_ip6="fd00:172:30::11"
                client_ip6="fd00:192:168:50::11"
                ;;
            ha-node3)
                backend_ip6="fd00:172:30::12"
                client_ip6="fd00:192:168:50::12"
                ;;
        esac

        # Check if addresses are already present
        local has_backend=0 has_client=0
        if $CONTAINER_RUNTIME exec "$node" ip -6 addr show backend 2>/dev/null | grep -q "$backend_ip6"; then
            has_backend=1
        fi
        if $CONTAINER_RUNTIME exec "$node" ip -6 addr show lan 2>/dev/null | grep -q "$client_ip6"; then
            has_client=1
        fi

        if [ "$has_backend" -eq 0 ]; then
            info "Adding $backend_ip6/64 to $node backend interface"
            $CONTAINER_RUNTIME exec "$node" ip -6 addr add "$backend_ip6/64" dev backend 2>/dev/null || true
        fi

        if [ "$has_client" -eq 0 ]; then
            info "Adding $client_ip6/64 to $node lan interface"
            $CONTAINER_RUNTIME exec "$node" ip -6 addr add "$client_ip6/64" dev lan 2>/dev/null || true
        fi
    done

    info "IPv6 workaround applied successfully"
}

configure_node_from_env() {
    local node="$1"

    # Get environment variables from container (use sh -c since printenv not available)
    local node_name node_priority peer_ip peer_ip_2 vip_addr vip_mask vip6_addr vip6_prefix
    node_name=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $NODE_NAME' 2>/dev/null)
    [ -z "$node_name" ] && node_name="$node"
    node_priority=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $NODE_PRIORITY' 2>/dev/null)
    [ -z "$node_priority" ] && node_priority="100"
    peer_ip=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $PEER_IP' 2>/dev/null)
    peer_ip_2=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $PEER_IP_2' 2>/dev/null)
    vip_addr=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $VIP_ADDRESS' 2>/dev/null)
    [ -z "$vip_addr" ] && vip_addr="$VIP_ADDRESS"
    vip_mask=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $VIP_NETMASK' 2>/dev/null)
    [ -z "$vip_mask" ] && vip_mask="$VIP_NETMASK"
    vip6_addr=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $VIP6_ADDRESS' 2>/dev/null)
    vip6_prefix=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $VIP6_PREFIX' 2>/dev/null)

    # Create ha-cluster and dhcp config
    $CONTAINER_RUNTIME exec "$node" sh -c "
        # Clear any existing ha-cluster config and start fresh
        rm -f /etc/config/ha-cluster
        touch /etc/config/ha-cluster

        # Global config
        uci set ha-cluster.config=config
        uci set ha-cluster.config.enabled='1'
        uci set ha-cluster.config.encryption_key='$TEST_KEY'
        uci set ha-cluster.config.sync_method='owsync'

        # VRRP instance config
        uci set ha-cluster.main=vrrp_instance
        uci set ha-cluster.main.vrid='51'
        uci set ha-cluster.main.interface='lan'
        uci set ha-cluster.main.priority='$node_priority'
        uci set ha-cluster.main.nopreempt='0'

        # VIP config
        uci set ha-cluster.lan=vip
        uci set ha-cluster.lan.enabled='1'
        uci set ha-cluster.lan.vrrp_instance='main'
        uci set ha-cluster.lan.interface='lan'
        uci set ha-cluster.lan.address='$vip_addr'
        uci set ha-cluster.lan.netmask='$vip_mask'

        # IPv6 VIP config (if available)
        if [ -n \"$vip6_addr\" ]; then
            uci set ha-cluster.lan.address6='$vip6_addr'
            uci set ha-cluster.lan.prefix6='$vip6_prefix'
        fi

        # Peer config (first peer)
        if [ -n \"$peer_ip\" ]; then
            uci set ha-cluster.peer1=peer
            uci set ha-cluster.peer1.name='peer1'
            uci set ha-cluster.peer1.address='$peer_ip'
        fi

        # Peer config (second peer for 3-node clusters)
        if [ -n \"$peer_ip_2\" ]; then
            uci set ha-cluster.peer2=peer
            uci set ha-cluster.peer2.name='peer2'
            uci set ha-cluster.peer2.address='$peer_ip_2'
        fi

        # Service config
        uci set ha-cluster.dhcp=service
        uci set ha-cluster.dhcp.enabled='1'
        uci set ha-cluster.dhcp.sync_leases='1'
        uci add_list ha-cluster.dhcp.config_files='dhcp'

        # Test service for config sync tests
        uci set ha-cluster.test=service
        uci set ha-cluster.test.enabled='1'
        uci add_list ha-cluster.test.config_files='test_sync'
        uci add_list ha-cluster.test.config_files='test_sync2'

        # Exclude config (don't sync node-specific files)
        uci set ha-cluster.exclude=exclude
        uci add_list ha-cluster.exclude.file='network'
        uci add_list ha-cluster.exclude.file='system'
        uci add_list ha-cluster.exclude.file='owsync'
        uci add_list ha-cluster.exclude.file='ha-cluster'

        uci commit ha-cluster

        # Copy DHCP config from mounted directory if available
        if [ -f /mnt/config/dhcp ]; then
            cp /mnt/config/dhcp /etc/config/dhcp
        fi

        # Configure dnsmasq for container environment
        uci set dhcp.@dnsmasq[0].dnssec='0'
        uci set dhcp.@dnsmasq[0].ubus='dnsmasq'
        uci commit dhcp

        # Create required directories for dnsmasq
        mkdir -p /tmp/resolv.conf.d /tmp/dnsmasq.d /var/run
        touch /tmp/resolv.conf.d/resolv.conf.auto
        touch /tmp/dhcp.leases
    "

    info "  $node configured (priority=$node_priority, peers=$([ -n \"$peer_ip\" ] && echo -n \"$peer_ip\")$([ -n \"$peer_ip_2\" ] && echo -n \" $peer_ip_2\"))"
}

start_services() {
    header "Starting HA Services"

    local nodes="ha-node1 ha-node2"
    local priorities="200 100"
    if [ "$THREE_NODE" = "true" ]; then
        nodes="ha-node1 ha-node2 ha-node3"
        priorities="200 100 50"
    fi

    # Note: procd is already running as PID 1 (started by entrypoint.sh exec)
    # It provides hotplug ubus objects (hotplug.dhcp, etc.) needed for
    # the dhcp-script -> hotplug -> lease-sync chain

    # Wait for procd to be fully ready on all nodes
    for node in $nodes; do
        if ! wait_for "procd on $node" 15 "$CONTAINER_RUNTIME exec $node ubus list | grep -q '^service\$'"; then
            echo "Warning: procd service not available on $node"
        fi
    done

    # Start dnsmasq on all nodes via init script
    for node in $nodes; do
        info "Starting dnsmasq on $node..."

        # Get node's client IP for DHCP range configuration
        local client_ip
        client_ip=$($CONTAINER_RUNTIME exec "$node" sh -c 'echo $NODE_NAME' 2>/dev/null)
        case "$client_ip" in
            ha-node1) client_ip="192.168.50.10" ;;
            ha-node2) client_ip="192.168.50.11" ;;
            ha-node3) client_ip="192.168.50.12" ;;
            *) client_ip="192.168.50.10" ;;
        esac

        # Configure dnsmasq UCI settings for container environment
        # These override the defaults for proper DHCP operation
        $CONTAINER_RUNTIME exec "$node" sh -c "
            uci set dhcp.@dnsmasq[0].interface='lan'
            uci set dhcp.@dnsmasq[0].localservice='0'
            # Force DHCP server to start even if another DHCP server is detected
            # This is required for HA where both nodes run dnsmasq as DHCP servers
            uci set dhcp.lan.force='1'
            uci commit dhcp

            # Create a DHCP range if not already configured
            # Check if pool section exists
            if ! uci show dhcp.lan 2>/dev/null | grep -q 'dhcp.lan=dhcp'; then
                uci set dhcp.lan=dhcp
                uci set dhcp.lan.interface='lan'
                uci set dhcp.lan.start='100'
                uci set dhcp.lan.limit='150'
                uci set dhcp.lan.leasetime='12h'
                uci commit dhcp
            fi
        "

        # Start dnsmasq via init script (procd manages it)
        $CONTAINER_RUNTIME exec "$node" /etc/init.d/dnsmasq start

        # Wait for dnsmasq to be ready with ubus
        if ! wait_for "dnsmasq on $node" 15 "$CONTAINER_RUNTIME exec $node ubus list dnsmasq"; then
            echo "Warning: dnsmasq ubus not available on $node"
        fi
    done

    # Start ha-cluster (which starts keepalived, owsync, lease-sync)
    local idx=1
    for node in $nodes; do
        local priority=$(echo "$priorities" | cut -d' ' -f$idx)
        info "Starting ha-cluster on $node (priority=$priority)..."

        # Start ha-cluster via init script - this generates keepalived.conf
        # and starts keepalived, owsync, and lease-sync as procd instances
        $CONTAINER_RUNTIME exec "$node" /etc/init.d/ha-cluster start

        idx=$((idx + 1))
    done

    info "Waiting for cluster to stabilize..."
    sleep 3

    # Wait for keepalived to be running on all nodes
    for node in $nodes; do
        if ! wait_for "keepalived on $node" 30 "$CONTAINER_RUNTIME exec $node pgrep keepalived"; then
            echo "Warning: keepalived not running on $node"
        fi
    done

    # Wait for VIP to be assigned
    if ! wait_for "VIP assignment" 15 "has_vip ha-node1 || has_vip ha-node2"; then
        echo "Warning: VIP not assigned to any node"
    fi

    # owsync and lease-sync are already started by ha-cluster init script
    # which was called above. Just wait for them to be ready.
    sleep 2

    # Verify services started
    for node in $nodes; do
        if ! $CONTAINER_RUNTIME exec "$node" pgrep owsync >/dev/null 2>&1; then
            echo "Warning: owsync not running on $node"
        fi
        if ! $CONTAINER_RUNTIME exec "$node" pgrep lease-sync >/dev/null 2>&1; then
            echo "Warning: lease-sync not running on $node"
        fi
    done

    info "Cluster services started"
}

print_status() {
    header "Cluster Status"

    cd "$TEST_DIR/compose"

    echo ""
    echo "Containers:"
    $COMPOSE_CMD ps

    echo ""
    echo "Services:"
    for node in ha-node1 ha-node2; do
        echo "  $node:"
        for svc in keepalived owsync lease-sync dnsmasq; do
            if $CONTAINER_RUNTIME exec "$node" pgrep -x "$svc" >/dev/null 2>&1; then
                echo "    $svc: running"
            else
                echo "    $svc: stopped"
            fi
        done
    done

    echo ""
    echo "VIP Status:"
    for node in ha-node1 ha-node2; do
        if $CONTAINER_RUNTIME exec "$node" ip addr show 2>/dev/null | grep -q "$VIP_ADDRESS"; then
            echo "  $node: HAS VIP ($VIP_ADDRESS)"
        else
            echo "  $node: no VIP"
        fi
    done

    echo ""
    echo "========================================="
    echo "Setup Complete!"
    echo "========================================="
    echo ""
    echo "Run tests with:"
    echo "  $TEST_DIR/scripts/run-tests.sh"
    echo ""
    echo "Access nodes with:"
    echo "  $CONTAINER_RUNTIME exec -it ha-node1 sh"
    echo "  $CONTAINER_RUNTIME exec -it ha-node2 sh"
    echo ""
    echo "Tear down with:"
    echo "  $TEST_DIR/scripts/teardown.sh"
    echo ""
}

# ============================================
# Main
# ============================================

main() {
    check_prerequisites

    if [ "$SKIP_BUILD" = "false" ]; then
        ensure_rootfs
        ensure_packages
        build_images
    fi

    if [ "$BUILD_ONLY" = "true" ]; then
        info "Build complete (--build-only specified)"
        exit 0
    fi

    start_cluster
    configure_nodes
    apply_ipv6_workaround
    start_services
    print_status
}

main
