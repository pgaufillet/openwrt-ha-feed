# OpenWrt HA Cluster Feed

A high-availability solution for OpenWrt routers, providing automatic failover, configuration synchronization, and DHCP lease replication.

## Features

- **Virtual IP Failover** - VRRP-based failover with sub-second switchover (keepalived)
- **Configuration Sync** - Bi-directional, encrypted sync of UCI configs between nodes (owsync)
- **DHCP Lease Sync** - Real-time lease replication for seamless client experience (lease-sync)
- **Web Interface** - LuCI integration for easy setup and monitoring
- **IPv4 and IPv6** - Full dual-stack support for VIPs and sync traffic

## Packages

| Package | Description |
|---------|-------------|
| `ha-cluster` | Core orchestration - manages keepalived, owsync, and lease-sync |
| `luci-app-ha-cluster` | Web interface for configuration and monitoring |
| `owsync` | Lightweight encrypted file synchronization daemon |
| `lease-sync` | Real-time DHCP lease replication daemon |
| `dnsmasq-ha` | dnsmasq with ubus lease management patches |

## Requirements

- **OpenWrt 24.10**
- **Two or more routers** on a shared network segment
- **dnsmasq-ha** (for DHCP lease sync)

## Installation

### Add the Feed

```bash
# Add feed to /etc/openwrt_distfeeds.conf or feeds.conf
echo "src-git hacluster https://github.com/pgaufillet/openwrt-ha-feed.git" >> feeds.conf

# Update and install
./scripts/feeds update hacluster
./scripts/feeds install -a -p hacluster
```

### Install Packages

```bash
# Install the complete HA solution
opkg update
opkg install ha-cluster luci-app-ha-cluster

# Or install individual components
opkg install owsync        # Config sync only
opkg install lease-sync    # DHCP sync only
```

## Quick Start

### Quick Setup (5 minutes)

**On both routers:**

1. Install packages:
   ```bash
   opkg update
   opkg install ha-cluster luci-app-ha-cluster
   ```

2. Open LuCI: **Services → High Availability → Quick Setup**

3. Configure:
   - Enable HA Cluster
   - Set node name (e.g., `router1`, `router2`)
   - Set priority (higher = preferred master, e.g., 100 and 90)
   - Add peer IP address
   - Add Virtual IP for your LAN interface
   - Generate and copy encryption key to both nodes

4. Save & Apply

5. Verify: Check **Status** tab for cluster health

### Manual Configuration

Edit `/etc/config/ha-cluster`:

```
config global
    option enabled '1'
    option node_name 'router1'
    option priority '100'

config peer
    option address '192.168.1.2'

config vip
    option interface 'lan'
    option address '192.168.1.254'
    option netmask '255.255.255.0'

config security
    option encryption_key '0123456789abcdef...'  # 64 hex chars
```

Start the cluster:
```bash
/etc/init.d/ha-cluster enable
/etc/init.d/ha-cluster start
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        ha-cluster                           │
│                    (Orchestration Layer)                    │
└─────────┬──────────────────┬──────────────────┬─────────────┘
          │                  │                  │
          ▼                  ▼                  ▼
┌─────────────────┐ ┌──────────────┐ ┌──────────────────┐
│   keepalived    │ │   owsync     │ │   lease-sync     │
│     (VRRP)      │ │ (Config Sync)│ │  (DHCP Sync)     │
└─────────────────┘ └──────────────┘ └──────────────────┘
```

- **keepalived**: Manages VRRP for virtual IP failover
- **owsync**: Syncs UCI configuration files with AES-256-GCM encryption
- **lease-sync**: Replicates DHCP leases in real-time via ubus and UDP with AES-256-GCM encryption

## Documentation

- [ha-cluster Design](ha-cluster/README.md) - Architecture and configuration details
- [LuCI Application](luci-app-ha-cluster/README.md) - Web interface guide
- [owsync](https://github.com/pgaufillet/owsync) - Config sync daemon (standalone project)
- [Test Infrastructure](tests/README.md) - Container-based testing

## Security

- **Encryption**: All sync traffic encrypted with AES-256-GCM (PSK)
- **Key Management**: Keys stored in config files, never exposed on command line
- **Network**: Designed for trusted LAN segments; use VPN for untrusted networks

## Known Limitations (v1.0)

### IPv6 Support

**What works:**
- IPv6 Virtual IPs (dual-stack VIP failover)
- IPv6 sync traffic between nodes
- SLAAC (default OpenWrt) - clients self-configure, no lease sync needed
- Prefix Delegation from ISP - unaffected (odhcp6c is separate)
- PD delegation to downstream routers - works (downstream may get different prefix on failover, which is normal IPv6 renumbering behavior)

**What doesn't work:**
- Stateful DHCPv6 lease sync when using **odhcpd** (OpenWrt's default DHCPv6 server)

**Why:** lease-sync integrates with dnsmasq, not odhcpd. Since default OpenWrt uses SLAAC (stateless), most users are unaffected.

**Recommended Workaround - Disable odhcpd:** The simplest and most reliable approach for v1.0:

```bash
# Disable odhcpd, let dnsmasq handle all DHCP/RA
uci set dhcp.odhcpd.enabled='0'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci commit dhcp
/etc/init.d/odhcpd stop
/etc/init.d/dnsmasq restart
```

This enables full DHCPv6 lease sync but loses odhcpd-specific features (PD relay, NDP proxy).

**Advanced Workaround - Hybrid Architecture (UNTESTED):** For experienced users who need odhcpd's unique features:

```bash
# /etc/config/dhcp - dnsmasq handles RA + DHCPv6 + DNS (lease-sync works)
config dhcp 'lan'
    option interface 'lan'
    option dhcpv4 'server'
    option dhcpv6 'server'      # dnsmasq handles DHCPv6 addresses
    option ra 'server'          # dnsmasq sends RA

# CRITICAL: Explicitly disable odhcpd on LAN interface
config dhcp 'lan_odhcpd'
    option interface 'lan'
    option ra 'disabled'        # Don't send RA (dnsmasq does it)
    option dhcpv6 'disabled'    # Don't do DHCPv6 (dnsmasq does it)
    option ndp 'hybrid'         # NDP proxy only

# odhcpd global settings
config odhcpd 'odhcpd'
    option maindhcp '0'
```

This should preserve:
- ✅ DHCPv6 lease sync (via dnsmasq + lease-sync)
- ✅ NDP proxy (odhcpd)
- ⚠️ PD relay to downstream (works, but downstream may experience lease expiration delay on failover)

**⚠️ Warning:** This hybrid configuration has not been tested in production. Requires experienced user configuration. Please report any issues.

## Troubleshooting

### Check Cluster Status
```bash
# Via CLI
ubus call ha-cluster status

# Via LuCI
Services → High Availability → Status
```

### View Logs
```bash
logread | grep -E "(ha-cluster|keepalived|owsync|lease-sync)"
```

### Common Issues

| Issue | Solution |
|-------|----------|
| VIP not appearing | Check interface name matches UCI config |
| Sync not working | Verify encryption keys match on both nodes |
| Peer unreachable | Check firewall allows ports 4321 (owsync), 4322 (lease-sync), 112 (VRRP) |
| Split brain | Ensure reliable network between nodes |

## Development

### Setting Up the Build Environment

A setup script is provided to clone and configure an OpenWrt buildroot for compiling the feed packages:

```bash
# Default setup (OpenWrt 24.10.5, x86_64 config)
scripts/setup-openwrt-buildroot.sh ../openwrt

# Build all packages
cd ../openwrt
make package/ha-cluster/compile V=s
make package/owsync/compile V=s
make package/lease-sync/compile V=s
make package/dnsmasq-ha/compile V=s
make package/luci-app-ha-cluster/compile V=s
```

Built `.ipk` files are output to `bin/packages/*/ha_feed/`.

See `scripts/setup-openwrt-buildroot.sh --help` for options (custom OpenWrt version, config file, etc.).

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
