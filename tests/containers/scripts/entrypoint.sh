#!/bin/sh
# entrypoint.sh - Container startup script for HA cluster testing
#
# This script initializes the container environment and then execs procd
# as PID 1, making the container behave like a real OpenWrt system.
#
# Why procd as PID 1 matters:
# - procd implements wait() to reap zombie processes (orphaned children)
# - procd manages services via init scripts (/etc/rc.d/S*)
# - procd provides the hotplug subsystem
# - This matches real OpenWrt behavior
#
# Without procd as PID 1, zombie processes accumulate because the
# placeholder process (e.g., tail -f /dev/null) doesn't reap children.

set -e

# Create required runtime directories
mkdir -p /var/run /var/lock /tmp /var/log

# Docker/Podman bind-mounts resolv.conf following the OpenWrt symlink chain
# (/etc/resolv.conf -> /tmp/resolv.conf), making /tmp/resolv.conf a mount point.
# Unmount it so dnsmasq init can freely manage /tmp/resolv.conf (rm + recreate).
umount /tmp/resolv.conf 2>/dev/null || true

# Copy mounted configs to /etc/config (if available)
# This allows node-specific configs to override the defaults baked into the image
if [ -d /mnt/config ] && ls /mnt/config/* >/dev/null 2>&1; then
    echo "Applying mounted configs from /mnt/config..."
    cp -f /mnt/config/* /etc/config/ 2>/dev/null || true
fi

# Start ubusd (message bus - required for all other services including procd)
# Note: procd expects ubusd to be running when it starts
echo "Starting ubusd..."
/sbin/ubusd &
sleep 1

# Wait for network interfaces to get IPs from Docker/Podman
# Docker assigns IPs before the container command runs, but we need to
# wait for them to be visible inside the container
echo "Waiting for network interfaces..."
for i in $(seq 1 30); do
    if ip addr show eth0 2>/dev/null | grep -q "inet " && \
       ip addr show eth1 2>/dev/null | grep -q "inet "; then
        echo "Network interfaces ready."
        break
    fi
    sleep 1
done

# Rename interfaces to logical names based on subnet
# This handles Docker/Podman non-deterministic network attachment order
# Result: 'lan' = client network (192.168.50.x), 'backend' = backend network (172.30.x.x)
# IMPORTANT: This must happen BEFORE procd starts netifd
rename_interfaces() {
    local client_subnet="192.168.50"
    local backend_subnet="172.30.0"
    local client_if="" backend_if=""
    local client_ip="" backend_ip=""
    local client_ip6="" backend_ip6=""

    # Detect which physical interface has which subnet and save IPs
    for iface in eth0 eth1; do
        local ip_addr
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d' ' -f2)
        if echo "$ip_addr" | grep -q "^${client_subnet}\."; then
            client_if="$iface"
            client_ip="$ip_addr"
        elif echo "$ip_addr" | grep -q "^${backend_subnet}\."; then
            backend_if="$iface"
            backend_ip="$ip_addr"
        fi
    done

    if [ -z "$client_if" ] || [ -z "$backend_if" ]; then
        echo "Warning: Could not detect network interfaces, skipping rename"
        return 1
    fi

    # Detect IPv6 global addresses (fd00: prefix) before renaming
    client_ip6=$(ip -6 addr show "$client_if" scope global 2>/dev/null | \
        grep -oE "inet6 fd00:[0-9a-f:]+/[0-9]+" | cut -d' ' -f2)
    backend_ip6=$(ip -6 addr show "$backend_if" scope global 2>/dev/null | \
        grep -oE "inet6 fd00:[0-9a-f:]+/[0-9]+" | cut -d' ' -f2)

    echo "Detected: client=$client_if ($client_ip${client_ip6:+, $client_ip6}), backend=$backend_if ($backend_ip${backend_ip6:+, $backend_ip6})"

    # Rename interfaces to logical names
    # Need to bring them down, rename, then bring back up and restore IPs
    ip link set "$client_if" down
    ip link set "$backend_if" down

    ip link set "$client_if" name lan
    ip link set "$backend_if" name backend

    ip link set lan up
    ip link set backend up

    # Restore IPv4 addresses (with /24 netmask)
    ip addr add "${client_ip}/24" dev lan 2>/dev/null || true
    ip addr add "${backend_ip}/24" dev backend 2>/dev/null || true

    # Restore IPv6 addresses if they were present
    if [ -n "$client_ip6" ]; then
        ip -6 addr add "$client_ip6" dev lan 2>/dev/null || true
    fi
    if [ -n "$backend_ip6" ]; then
        ip -6 addr add "$backend_ip6" dev backend 2>/dev/null || true
    fi

    echo "Interfaces renamed: $client_if -> lan, $backend_if -> backend"
}

rename_interfaces

# Enable core services so procd will start them during boot
# These create symlinks in /etc/rc.d/ which procd processes
echo "Enabling core services..."
for svc in rpcd; do
    if [ -x /etc/init.d/$svc ]; then
        /etc/init.d/$svc enable 2>/dev/null || true
    fi
done

# Disable services that setup.sh will configure and start later
# This prevents them from starting before configuration is applied
echo "Disabling services for later configuration..."
for svc in ha-cluster dnsmasq; do
    if [ -x /etc/init.d/$svc ]; then
        /etc/init.d/$svc disable 2>/dev/null || true
    fi
done

# Note: netifd is left enabled as it may be needed for some network features
# Docker manages the base interface configuration (IPs), but netifd handles
# additional OpenWrt-specific functionality

echo "Container initialization complete. Executing procd as PID 1..."

# Exec procd as PID 1
# procd will:
# - Take over as PID 1 (replacing this shell)
# - Mount /proc, /sys, /dev (if needed)
# - Process /etc/inittab
# - Start services from /etc/rc.d/S*
# - Handle SIGCHLD (reap zombie processes)
# - Manage service lifecycle
exec /sbin/procd
