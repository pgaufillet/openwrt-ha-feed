# Changelog

All notable changes to this feed are documented in this file. Each entry
is a feed release (git tag `vX.Y.Z`) and lists the package versions it
ships. lease-sync and owsync live in their own repositories: this file
gives their version and links to their changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Feed tags follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
the major version changes when an upgrade needs action (configuration
schema change, all nodes upgraded together). Each package keeps its own
version.

## [2.0.0] - Unreleased

Before upgrading from 1.0.x, read
[Upgrading from 1.0.x to 2.0.0](ha-cluster/README.md#upgrading): the
configuration is migrated in place, and all nodes must be upgraded
together, BACKUP nodes first: the upgrade restarts keepalived once.

Builds for OpenWrt 25.12 should use the feed's new `openwrt-25.12`
branch: `master` now follows OpenWrt `main` (see
[Add the Feed](README.md#add-the-feed)).

| Package | 1.0.0 | 2.0.0 |
|---------|-------|-------|
| `ha-cluster` | 1.0.0 | 2.0.0 |
| `luci-app-ha-cluster` | 1.0.0 | 2.0.0 |
| `lease-sync` | 1.0.0 | 1.2.1 ([changelog](https://github.com/pgaufillet/lease-sync/blob/v1.2.1/CHANGELOG.md)) |
| `owsync` | 1.2.0 | 1.3.0 ([changelog](https://github.com/pgaufillet/owsync/blob/v1.3.0/CHANGELOG.md)) |
| `dnsmasq-ha` | 2.90 | 2.93 |

### Platform
- Feed branches: `master` follows OpenWrt `main`, `openwrt-25.12` follows
  OpenWrt 25.12.
- OpenWrt 25.12 and its apk package manager. OpenWrt 24.10 (opkg) is no
  longer supported.
- Docker build environment based on the OpenWrt SDK, for any target and
  stable release, with parallel and incremental builds.
- The feed can be hosted as a signed apk repository (public key in
  `keys/`).
- `scripts/install-ha-cluster.sh` installs the cluster on a router and
  swaps dnsmasq for dnsmasq-ha once every dependency is in place. It no
  longer installs `kmod-ipt-ipset`.

### dnsmasq-ha
- Updated to dnsmasq 2.93: fixes CVE-2026-2291, CVE-2026-4890,
  CVE-2026-4891, CVE-2026-4892, CVE-2026-4893 and CVE-2026-5172.
- Follows the stock OpenWrt 25.12 dnsmasq package: same `files/` and
  patches, built with the dnsmasq-full default options (nftset, no ipset,
  TFTP).
- ubus lease methods: fixed an out-of-bounds write in the `get_leases`
  MAC formatting, hardened input handling, and `add_lease` rejects an
  `is_temporary` mismatch.

### ha-cluster
Configuration (breaking, migrated on upgrade except the first item):
- VRRP settings move to `vrrp_instance` sections; each VIP names its
  instance, and the VIPs of an instance fail over together. A
  configuration from the 1.0.0 tag, with `vrid` and `priority` on each
  VIP, is not converted: recreate its VIPs after upgrading.
- `service` sections become `sync_group` sections.
- Lease sync has its own global switch, `lease_sync`, instead of the DHCP
  group's `sync_leases`.
- Peer `sync_enabled '0'` becomes `vrrp_only '1'`.
- Removed: the wireless sync group, `sync_method`,
  `lease_sync_persist_interval`.

Behaviour:
- A VIP without an `enabled` option is enabled, as LuCI shows it.
- owsync and lease-sync are optional: each runs only when installed and
  needed. A daemon that is needed but not installed is logged as a
  warning.
- With unicast peers, an IPv6-only instance runs as `<name>` with its own
  VRID (no longer `<name>_v6` with VRID+128); with IPv6 unicast peers and
  IPv4 VIPs only, the instance advertises no address. Unicast VRRP keeps
  one address family per instance.
- A warning when dnsmasq is authoritative while leases or the DHCP
  configuration are synced.
- keepalived is reloaded on a configuration change, dnsmasq is restarted
  only when its overlay changed, and package upgrades keep the boot state.
- The generated `keepalived.conf` is created with mode 0600.

### luci-app-ha-cluster
- Pages follow the new configuration model: VRRP instances, VIPs per
  instance (IPv4 and IPv6), sync groups.
- Status page: role per VRRP instance, the daemons the configuration
  needs, and a retried keepalived dump (the role is no longer shown as
  UNKNOWN after an empty dump).
- Layout for phones, theme fixes, no default values written to the
  configuration, corrected unicast help texts.

### lease-sync package
- The standalone init script passes the security options to the daemon
  and keeps the boot state across upgrades.

### Documentation
- Package links in the README and a dnsmasq-ha README.
- Upgrade notes, attended sysupgrade, DHCP prerequisites, and the known
  limits (one dnsmasq section, unicast derivation).

## [1.0.0] - 2026-03-02

Initial release, for OpenWrt 24.10: `ha-cluster` 1.0.0,
`luci-app-ha-cluster` 1.0.0, `lease-sync` 1.0.0, `owsync` 1.2.0,
`dnsmasq-ha` 2.90.
