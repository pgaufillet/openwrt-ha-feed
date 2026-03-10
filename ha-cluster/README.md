# ha-cluster - High Availability for OpenWrt

Meta-package that orchestrates keepalived (VRRP), owsync (config sync), and
lease-sync (DHCP lease sync) to provide seamless failover between OpenWrt
routers.

## Installation

### Automated (recommended)

Copy the installation script to your router and run it:

```sh
scp scripts/install-ha-cluster.sh root@router:/tmp/
ssh root@router sh /tmp/install-ha-cluster.sh
```

The script handles the dnsmasq-to-dnsmasq-ha swap safely by pre-installing
dependencies and pre-downloading packages while DNS is still available.

### Manual

If you prefer to install manually, or if the script fails:

```sh
# 1. Update package lists
opkg update

# 2. Pre-install ALL dependencies from official feeds (while DNS works)
opkg install libnettle kmod-ipt-ipset libnetfilter-conntrack nftables-json
opkg install keepalived
opkg install libopenssl3

# 3. Download ALL ha_feed packages locally
cd /tmp
opkg download dnsmasq-ha ha-cluster owsync lease-sync luci-app-ha-cluster

# 4. Swap dnsmasq for dnsmasq-ha
opkg remove dnsmasq          # or: opkg remove dnsmasq-full
opkg install /tmp/dnsmasq-ha_*.ipk

# 5. Install remaining packages from local files
opkg install /tmp/owsync_*.ipk /tmp/lease-sync_*.ipk
opkg install /tmp/ha-cluster_*.ipk /tmp/luci-app-ha-cluster_*.ipk
```

**Why so many steps?** dnsmasq-ha replaces stock dnsmasq, but opkg cannot
auto-remove conflicting packages. Removing dnsmasq kills DNS resolution,
so ALL dependencies and packages must be pre-downloaded before the swap.

## Dependencies

- `keepalived` - VRRP failover
- `owsync` - Bidirectional config file synchronization
- `lease-sync` - Real-time DHCP lease replication via dnsmasq ubus
- `dnsmasq-ha` - dnsmasq with ubus lease methods

Optional: `luci-app-ha-cluster` for web interface.

## How It Works

ha-cluster reads `/etc/config/ha-cluster` and generates flat config files
for each service under `/tmp/ha-cluster/`:

```
/etc/config/ha-cluster  →  /tmp/ha-cluster/keepalived.conf
                        →  /tmp/ha-cluster/owsync.conf
                        →  /tmp/ha-cluster/lease-sync.conf
```

All three daemons are started as procd instances by ha-cluster. Do **not**
use standalone init scripts (`/etc/init.d/keepalived`, `/etc/init.d/owsync`,
`/etc/init.d/lease-sync`) while ha-cluster is enabled — they generate their
own configs and would conflict.

Any `uci commit ha-cluster` automatically triggers a service reload.

## Quick Start

```sh
# Generate an encryption key
KEY=$(hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom)

# Minimal configuration
uci set ha-cluster.config.enabled='1'
uci set ha-cluster.config.node_priority='100'
uci set ha-cluster.config.encryption_key="$KEY"

# Add a peer
uci add ha-cluster peer
uci set ha-cluster.@peer[-1].name='router2'
uci set ha-cluster.@peer[-1].address='192.168.1.2'

# Create a VRRP instance (all VIPs in same instance fail over together)
uci set ha-cluster.main=vrrp_instance
uci set ha-cluster.main.vrid='51'
uci set ha-cluster.main.interface='lan'
uci set ha-cluster.main.priority='100'
uci set ha-cluster.main.nopreempt='1'

# Configure a VIP
uci set ha-cluster.lan=vip
uci set ha-cluster.lan.enabled='1'
uci set ha-cluster.lan.vrrp_instance='main'
uci set ha-cluster.lan.interface='br-lan'
uci set ha-cluster.lan.address='192.168.1.254'
uci set ha-cluster.lan.netmask='255.255.255.0'

# Apply
uci commit ha-cluster
```

Repeat on each peer node with the appropriate priority and peer addresses.

## UCI Configuration

All configuration lives in `/etc/config/ha-cluster`.

### Global settings (`config global 'config'`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `0` | Enable/disable ha-cluster |
| `node_priority` | int | `100` | VRRP priority (1-255, higher wins MASTER) |
| `vrrp_transport` | string | `multicast` | VRRP transport: `multicast` or `unicast`. When `unicast`, auto-derives addresses from peer config |
| `sync_method` | string | `owsync` | Sync backend: `owsync` or `none` |
| `sync_encryption` | bool | `1` | Encrypt owsync traffic (AES-256-GCM) |
| `encryption_key` | string | | 256-bit hex key (use LuCI "Generate" button or `hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom`) |
| `sync_port` | int | `4321` | owsync TCP port |
| `sync_dir` | string | `/etc/config` | Directory to synchronize |
| `bind_address` | string | | Local IP for sync traffic (use real IP, not VIP) |

### VRRP Instances (`config vrrp_instance '<name>'`)

Each section defines a VRRP instance. All VIPs referencing the same instance
fail over atomically as a group (one advertisement, one failover event).

When any VIP in the group has `address6` set, a second VRRP instance is
created automatically using VRID+128 for all IPv6 VIPs.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vrid` | int | | VRRP router ID (1-127, 128+ reserved for IPv6) |
| `interface` | string | | Primary interface for VRRP advertisements |
| `priority` | int | | Override global `node_priority` for this instance |
| `nopreempt` | bool | `1` | Don't reclaim MASTER on recovery |
| `preempt_delay` | int | | Delay before preempting (seconds) |
| `garp_master_delay` | int | | Gratuitous ARP delay after becoming MASTER |
| `advert_int` | int | `1` | VRRP advertisement interval (seconds) |
| `track_interface` | list | | Interfaces to track for failover |
| `track_script` | list | | Health check script names |
| `auth_type` | string | `none` | VRRP auth: `none`, `pass`, or `ah` |
| `auth_pass` | string | | VRRP auth password |
| `unicast_src_ip` | string | | Source IP for unicast VRRP (overrides auto-derivation) |
| `unicast_peer` | list | | Unicast peer IPs (overrides auto-derivation) |

### Virtual IPs (`config vip '<name>'`)

Each VIP references a `vrrp_instance` section. Multiple VIPs can share the
same instance for atomic failover.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `1` | Enable this VIP |
| `vrrp_instance` | string | | Name of `vrrp_instance` section |
| `interface` | string | | Network interface for this VIP (e.g. `br-lan`) |
| `address` | string | | Virtual IPv4 address |
| `netmask` | string | `255.255.255.0` | IPv4 netmask |
| `address6` | string | | Virtual IPv6 address (optional, uses VRID+128) |
| `prefix6` | int | `64` | IPv6 prefix length |

### Peers (`config peer`)

| Option | Type | Description |
|--------|------|-------------|
| `name` | string | Peer identifier |
| `address` | string | Peer IP address |
| `source_address` | string | Local IP to use when contacting this peer (also used as `unicast_src_ip` for auto-derivation) |
| `sync_enabled` | bool | `1` | Enable owsync/lease-sync for this peer. Set to `0` for non-OpenWrt peers (VRRP-only) |

### Services (`config service '<name>'`)

Each service section defines a sync group for owsync.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `0` | Enable sync for this group |
| `config_files` | list | | UCI config names or paths to sync |
| `sync_leases` | bool | `0` | Enable lease-sync daemon (dhcp service only) |

### Exclusions (`config exclude`)

| Option | Type | Description |
|--------|------|-------------|
| `file` | list | UCI config names to never sync |

Default exclusions: `network`, `system`, `owsync`, `ha-cluster`, `wireless`.

### Health check scripts (`config script '<name>'`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `script` | string | | Command to run |
| `interval` | int | `5` | Check interval (seconds) |
| `timeout` | int | | Script timeout (seconds, keepalived default applies) |
| `weight` | int | | Priority adjustment on failure (keepalived default applies) |
| `rise` | int | | Successes before marking UP (keepalived default applies) |
| `fall` | int | | Failures before marking DOWN (keepalived default applies) |
| `user` | string | | User to run script as |

### Advanced settings (`config advanced`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `log_level` | int | `2` | 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG |
| `owsync_log_level` | int | `2` | owsync log level |
| `sync_interval` | int | `30` | owsync poll interval (seconds) |
| `lease_sync_port` | int | `5378` | lease-sync UDP port |
| `lease_sync_interval` | int | `30` | lease-sync periodic sync (seconds) |
| `lease_sync_peer_timeout` | int | `120` | Peer timeout (seconds) |
| `lease_sync_persist_interval` | int | `60` | Persist interval (seconds) |
| `lease_sync_log_level` | int | `2` | lease-sync log level |
| `max_auto_priority` | int | `0` | Auto-priority cap (0 = disabled) |
| `enable_notifications` | bool | `0` | Email notifications |
| `notification_email` | list | | Notification recipients |
| `notification_email_from` | string | | Sender address for notifications |
| `smtp_server` | string | | SMTP server address |

## State Change Hooks

keepalived state transitions trigger the OpenWrt hotplug system.
Custom scripts can be placed in `/etc/hotplug.d/keepalived/` with a
numeric prefix above 50 (e.g. `60-vpn-failover`).

Available environment variables:
- `ACTION` — `MASTER`, `BACKUP`, `FAULT`, or `STOP`
- `TYPE` — `INSTANCE`, `GROUP`, etc.
- `NAME` — instance name (e.g. `main`)

## Files

```
/etc/config/ha-cluster                  UCI configuration
/etc/init.d/ha-cluster                  procd init script (START=19, STOP=91)
/usr/lib/ha-cluster/ha-cluster.sh       Core library
/tmp/ha-cluster/                        Generated configs (runtime)
```

## License

MIT. See LICENSE file.

ha-cluster has been developed using Claude Code from Anthropic.

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
