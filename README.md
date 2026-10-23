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
| [`ha-cluster`](ha-cluster/README.md) | Core orchestration - manages keepalived, owsync, and lease-sync |
| [`luci-app-ha-cluster`](luci-app-ha-cluster/README.md) | Web interface for configuration and monitoring |
| [`owsync`](https://github.com/pgaufillet/owsync) | Lightweight encrypted file synchronization daemon |
| [`lease-sync`](https://github.com/pgaufillet/lease-sync) | Real-time DHCP lease replication daemon |
| [`dnsmasq-ha`](dnsmasq-ha/README.md) | dnsmasq with ubus lease management patches |

## Requirements

- **OpenWrt 25.12**
- **Two or more routers** on a shared network segment
- **dnsmasq-ha** (for DHCP lease sync)

## Installation

### Add the Feed

In an OpenWrt buildroot or SDK, add the feed branch matching your OpenWrt
release to `feeds.conf`:

```bash
# feeds.conf replaces feeds.conf.default: start from a copy
[ -f feeds.conf ] || cp feeds.conf.default feeds.conf
# OpenWrt 25.12
echo "src-git hacluster https://github.com/pgaufillet/openwrt-ha-feed.git;openwrt-25.12" >> feeds.conf

./scripts/feeds update hacluster
./scripts/feeds install -a -p hacluster
```

Feed branches follow OpenWrt's: `master` follows OpenWrt `main`, and each
supported OpenWrt release branch has a feed branch of the same name
(`openwrt-25.12`). Changes land on `master`, then are cherry-picked to the
release branches. On each branch, dnsmasq-ha follows the dnsmasq package
of the matching OpenWrt branch.

### Disable a Legacy keepalived

When the keepalived package is installed or upgraded, its post-install
script starts the standalone keepalived service from
`/etc/config/keepalived`, before ha-cluster takes keepalived over. A VRRP
instance left in that file by an earlier setup can then become MASTER
alongside the cluster. On a router that ran keepalived before, stop it and
set its configuration aside before installing:

```bash
/etc/init.d/keepalived stop
/etc/init.d/keepalived disable
mv /etc/config/keepalived /etc/config/keepalived.legacy
```

The standalone service does not start when `/etc/config/keepalived` is
missing or has `option enabled '0'` in its `globals` section (the package
default). ha-cluster generates its own keepalived configuration and does
not read this file.

### Install Packages

No public package repository is published: build the packages and serve
them from your own repository (see
[Building and Hosting Your Own Package Repository](#building-and-hosting-your-own-package-repository)),
then install them with
[`scripts/install-ha-cluster.sh`](scripts/install-ha-cluster.sh) (see
[Configure Routers to Use the Feed](#4-configure-routers-to-use-the-feed)).
A plain `apk add` is not safe: lease-sync depends on dnsmasq-ha, which
replaces the stock dnsmasq serving the router's own DNS. The manual steps
are in [ha-cluster's installation notes](ha-cluster/README.md#installation).

## Upgrading

ha-cluster and luci-app-ha-cluster 2.0.0 change the schema of
`/etc/config/ha-cluster`; the existing file is migrated on install (see
below). Upgrade both packages together (e.g. `apk upgrade`): the 2.0.0
web interface does not work with a 1.x ha-cluster, nor the reverse.
Upgrade all nodes in the same maintenance window. The file is not synced
between nodes: check the migrated file on each one.

The full list of behaviour changes is in
[ha-cluster's upgrade notes](ha-cluster/README.md#upgrading). One needs
action: with unicast peers, a VRRP instance whose peers and VIPs are all
IPv6 now runs as `<name>` with its VRID instead of `<name>_v6` with
VRID+128. Nodes on different versions do not see each other for that
instance, and hotplug scripts matching `<name>_v6` must be updated.

### Sync options renamed

The sync options of `/etc/config/ha-cluster` were renamed after what they
do. When ha-cluster 2.0.0 is installed, a `uci-defaults` script migrates
the existing file once:

| Before | After |
|--------|-------|
| `config service '<name>'` | `config sync_group '<name>'` |
| `option sync_leases` in the `dhcp` group | `option lease_sync` in `config global 'config'` (an existing `lease_sync` is kept) |
| `option sync_leases` in any other group | removed (it was never read) |
| `option sync_method` other than `owsync` (e.g. `none`) | every sync group gets `enabled '0'`, and `sync_method` is removed |
| peer `option sync_enabled '0'` | peer `option vrrp_only '1'` |
| peer `option sync_enabled '1'` | removed (default) |

- When an option is changed, `uci commit` rewrites the file and drops its
  comments. A file that only needs its sections renamed keeps them.
- The migration leaves an already migrated file unchanged.
- A 1.0.x `config advanced` section without a name is named `advanced`,
  so that ha-cluster reads its settings (only the first one, if several).
- Scripts that set the old options must be updated: ha-cluster refuses to
  start with a `sync_method` other than `owsync`, and ignores
  `sync_leases` and `sync_enabled`.
- `ubus call owsync status` now reports `enabled` from the standalone
  owsync configuration (`/etc/config/owsync`) only; an owsync instance
  run by ha-cluster shows in its `status` field.

### Standalone keepalived

Upgrading the keepalived package runs `/etc/init.d/keepalived start` even
while ha-cluster keeps that service disabled. Before upgrading, make sure
`/etc/config/keepalived` is missing or disabled, as described in
[Disable a Legacy keepalived](#disable-a-legacy-keepalived).

### Attended Sysupgrade

The attended sysupgrade server (LuCI Attended Sysupgrade, `owut`) builds
the new image from the packages installed on the router, and only knows
the official ones. With the feed's packages installed, the build fails
with:

```
Impossible package selection: missing (dnsmasq-ha, ha-cluster, lease-sync, luci-app-ha-cluster, owsync)
```

Swap them out first, one node at a time, while the other node keeps the
VIPs:

1. Back up the router (`sysupgrade -b /tmp/backup.tar.gz`, then copy the
   file off the router).
2. sysupgrade only keeps the configuration of installed packages. Keep
   the files of the packages about to be removed, and the feed's signing
   key (the lines can stay for the next attended sysupgrade):

   ```bash
   cat >> /etc/sysupgrade.conf <<'EOF'
   /etc/config/ha-cluster
   /etc/config/owsync
   /etc/config/lease-sync
   /etc/owsync/
   /etc/lease-sync/
   /etc/apk/keys/ha_feed_apk.pem
   EOF
   ```

3. Stop ha-cluster: the peer takes over the VIPs.

   ```bash
   /etc/init.d/ha-cluster stop
   /etc/init.d/ha-cluster disable
   ```

4. While DNS still works, download the stock `dnsmasq` into an empty
   directory:

   ```bash
   mkdir -p /tmp/dnsmasq-stock && cd /tmp/dnsmasq-stock
   apk fetch dnsmasq
   ```

   If the router relies on the extra features of `dnsmasq-full` (nftset,
   DNSSEC), fetch it instead, with the libraries that are removed along
   with `dnsmasq-ha` (OpenWrt 25.12 package names):

   ```bash
   apk fetch dnsmasq-full libnettle8 libgmp10 libnetfilter-conntrack3 kmod-nf-conntrack-netlink
   ```

5. Remove the feed's packages and install the downloaded ones (DNS is
   unavailable between the two commands). Official packages are signed
   through the repository index, not individually, so a local file needs
   `--allow-untrusted`:

   ```bash
   apk del luci-app-ha-cluster ha-cluster lease-sync owsync dnsmasq-ha
   apk add --allow-untrusted /tmp/dnsmasq-stock/*.apk
   ```

   `apk del` may print `Command failed: ubus call service delete
   { "name": "ha-cluster" } (Not found)`: ha-cluster is already stopped.
   Modified configuration files, such as `/etc/config/dhcp`, stay in
   place; apk writes the package's version next to them as `*.apk-new`.
6. Run the attended sysupgrade.
7. After the reboot, reinstall from the feed with
   [`scripts/install-ha-cluster.sh`](scripts/install-ha-cluster.sh) (see
   [Configure Routers to Use the Feed](#4-configure-routers-to-use-the-feed)).
   ha-cluster starts again from the kept `/etc/config/ha-cluster`. The
   new image starts the standalone keepalived if `/etc/config/keepalived`
   enables it: see
   [Disable a Legacy keepalived](#disable-a-legacy-keepalived).
8. Once the node is back in the cluster, upgrade the other one the same
   way.

## Quick Start

### Quick Setup (5 minutes)

**On both routers:**

1. Install the packages (see [Install Packages](#install-packages)):
   ```bash
   sh install-ha-cluster.sh
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
config global 'config'
    option enabled '1'
    option node_priority '100'
    option encryption_key '0123456789abcdef...'  # 64 hex chars

config peer
    option name 'router2'
    option address '192.168.1.2'

config vrrp_instance 'main'
    option vrid '51'
    option interface 'lan'
    option priority '100'
    option nopreempt '1'

config vip 'lan'
    option enabled '1'
    option vrrp_instance 'main'
    option interface 'br-lan'
    option address '192.168.1.254'
    option netmask '255.255.255.0'
```

Start the cluster:
```bash
/etc/init.d/ha-cluster enable
/etc/init.d/ha-cluster start
```

## Architecture

```
┌───────────────────────────────────────────────────────┐
│                      ha-cluster                       │
│                  (Orchestration Layer)                │
└───────┬──────────────────┬──────────────────┬─────────┘
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

## Known Limitations

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

**Recommended Workaround - Disable odhcpd:** The simplest and most reliable approach:

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
| Peer unreachable | Check the firewall allows owsync (TCP 4321), lease-sync (UDP 5378) and VRRP (IP protocol 112, or 51 with `auth_type 'ah'`) between the nodes |
| Split brain | Ensure reliable network between nodes |

## Development

### Building with Docker (quickest)

If you just want ready-to-install packages without setting up a build host, a
containerised build environment based on the official OpenWrt SDK is provided
in [`docker/`](docker/README.md):

```bash
# Build the image and compile all packages for x86-64
docker build -t ha-feed-build docker/
docker run --rm -v "$PWD/output:/output" ha-feed-build

# For another architecture and/or OpenWrt release, e.g. MediaTek Filogic
# (aarch64) on 25.12.1. Use the bare version number, without a "v" prefix.
docker build -t ha-feed-build-filogic \
  --build-arg OPENWRT_TARGET=mediatek/filogic \
  --build-arg OPENWRT_VERSION=25.12.1 \
  docker/
docker run --rm -v "$PWD/output:/output" ha-feed-build-filogic
```

The built `.apk` packages land in `./output/<arch>/ha_feed/`. The default
is x86-64 on OpenWrt 25.12.0; the matching SDK for any release/target is
resolved and checksum-verified automatically. See
[`docker/README.md`](docker/README.md) for version and target selection
(including which release to build against for multi-device compatibility),
index signing, and building from a local checkout.

### Setting Up the Build Environment (full buildroot)

A setup script is provided to clone and configure an OpenWrt buildroot for compiling the feed packages:

```bash
# Default setup (OpenWrt 25.12.0, x86_64 config)
scripts/setup-openwrt-buildroot.sh ../openwrt

# Build all packages
cd ../openwrt
make package/ha-cluster/compile V=s
make package/owsync/compile V=s
make package/lease-sync/compile V=s
make package/dnsmasq-ha/compile V=s
make package/luci-app-ha-cluster/compile V=s
```

Built packages are output to `bin/packages/*/ha_feed/`.

See `scripts/setup-openwrt-buildroot.sh --help` for options (custom OpenWrt version, config file, etc.).

### Building and Hosting Your Own Package Repository

If you want to serve pre-built packages to your routers without compiling on the router itself, you can create a signed apk repository hosted on any HTTP server on your LAN (NAS, Raspberry Pi, etc.). This applies to OpenWrt 25.12 and later; one repository serves all routers of the same architecture and release branch.

#### 1. Generate a Signing Key

apk repositories are signed with an ECDSA (prime256v1) key, generated the same way as the OpenWrt build key. Do this once and keep the private key safe (`keys/*.sec` is git-ignored):

```bash
openssl ecparam -name prime256v1 -genkey -noout -out keys/ha_feed_apk.sec
openssl ec -in keys/ha_feed_apk.sec -pubout -out keys/ha_feed_apk.pem
```

#### 2. Build the Packages and Sign the Index

The Docker build is the recommended way: it compiles the packages and generates the signed index (`packages.adb`) in one run when the private key is mounted and `SIGN_KEY` is set (see [`docker/README.md`](docker/README.md#signing-a-package-index), including which release to build against). For example, for MediaTek Filogic routers:

```bash
docker build -t ha-feed-build-filogic \
  --build-arg OPENWRT_TARGET=mediatek/filogic docker/
docker run --rm \
  -v "$PWD/output:/output" \
  -v "$PWD/keys/ha_feed_apk.sec:/keys/ha_feed_apk.sec:ro" \
  -e SIGN_KEY=/keys/ha_feed_apk.sec \
  ha-feed-build-filogic
```

The repository is `output/<arch>/ha_feed/` (e.g. `output/aarch64_cortex-a53/ha_feed/`): the `*.apk` packages and `packages.adb`. Build all five packages in one run, so that the index lists all of them.

From a full buildroot, `make package/index` generates and signs the index (`apk mkndx --sign`) with the buildroot's own key; pass `BUILD_KEY_APK_SEC=/path/to/keys/ha_feed_apk.sec` to sign with the feed key instead.

#### 3. Deploy to a Web Server

Copy the packages and the index to any directory served by an HTTP server:

```bash
FEED_DIR=output/<arch>/ha_feed
scp $FEED_DIR/*.apk $FEED_DIR/packages.adb myserver:/var/www/openwrt/ha_feed/
```

#### 4. Configure Routers to Use the Feed

On each router, install the public key under `/etc/apk/keys/` (copy `keys/ha_feed_apk.pem` there, e.g. with `scp`), then add the index URL to the custom feeds list:

```bash
# Public key copied to /etc/apk/keys/ha_feed_apk.pem beforehand
echo "http://myserver/openwrt/ha_feed/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
apk update
```

`apk update` must report no `UNTRUSTED signature` warning for the repository.

`dnsmasq-ha` replaces the stock `dnsmasq`, which serves the router's own DNS: once `dnsmasq` is removed, the router can no longer resolve the repository host. For the first installation, copy [`scripts/install-ha-cluster.sh`](scripts/install-ha-cluster.sh) to the router and run it: it installs the dependencies and downloads the feed packages first, then swaps `dnsmasq` for `dnsmasq-ha` offline. On a router that ran keepalived before, first [disable the legacy keepalived](#disable-a-legacy-keepalived).

```bash
sh install-ha-cluster.sh
```

#### 5. Updating the Feed

After a change, repeat steps 2 and 3, then on each router:

```bash
apk update
apk upgrade
```

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
