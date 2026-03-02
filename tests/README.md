# HA Cluster Test Infrastructure

Container-based test infrastructure for validating the full ha-cluster stack:
keepalived, owsync, lease-sync, and ha-cluster integration.

## Quick Start

```bash
# Build images and start 2-node cluster
./scripts/setup.sh

# Run Priority 1 tests (T01-T05)
./scripts/run-tests.sh

# Tear down when done
./scripts/teardown.sh
```

## Prerequisites

- **Container Runtime**: Podman (preferred) or Docker
- **Compose**: `podman compose` or `docker-compose`
- **Privileged Mode**: Required for VRRP testing (NET_ADMIN, NET_RAW capabilities)

### Pre-built Packages

The test infrastructure requires pre-built HA packages (`.ipk` files).

**IMPORTANT: Packages must be rebuilt from current source code before running tests.**

Tests may fail with confusing errors if packages are outdated. Common symptoms:
- lease-sync not receiving ubus events (event pattern mismatch)
- Missing functions or features in ha-cluster scripts
- Configuration options not recognized

**Rebuild packages before testing:**

```bash
# 1. Build packages from OpenWrt SDK
cd /path/to/openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make package/dnsmasq-ha/compile V=s
make package/lease-sync/compile V=s
make package/owsync/compile V=s
make package/ha-cluster/compile V=s
make package/luci-app-ha-cluster/compile V=s

# 2. Copy to tests/packages/
cp bin/packages/x86_64/ha-cluster/*.ipk /path/to/openwrt-ha-feed/tests/packages/

# 3. Force rebuild of container images
./scripts/setup.sh --force-rebuild
```

### OpenWrt Rootfs

The setup script will automatically download the OpenWrt rootfs if not present.
You can also copy an existing one:
```bash
cp /path/to/openwrt-x86-64-generic-rootfs.tar.gz images/
```

## Directory Structure

```
tests/
├── containers/
│   ├── Containerfile.node          # OpenWrt rootfs + HA packages
│   ├── Containerfile.dhcp-client   # DHCP client for lease testing
│   └── scripts/
│       ├── entrypoint.sh           # Container startup
│       └── wait-for-services.sh    # Readiness checks
│
├── compose/
│   ├── docker-compose.yml          # 2-node cluster
│   ├── docker-compose.3node.yml    # 3-node overlay
│   └── .env.example                # Configuration
│
├── configs/
│   ├── node1/                      # Node 1 UCI templates
│   ├── node2/                      # Node 2 UCI templates
│   └── shared/                     # Shared configuration
│
├── scenarios/
│   ├── 01-basic-startup.sh         # T01: Service startup
│   ├── 02-vrrp-election.sh         # T02: MASTER/BACKUP election
│   ├── 03-vrrp-failover.sh         # T03: VIP failover
│   ├── 04-config-sync.sh           # T04: Configuration sync
│   ├── 05-lease-sync.sh            # T05: DHCP lease sync
│   ├── 06-service-recovery.sh      # T06: Service crash recovery
│   ├── 07-startup-reconciliation.sh # T07: Stale lease cleanup
│   ├── 08-injection-retry-queue.sh  # T08: Retry queue validation
│   ├── 09-network-partition.sh     # T09: Split-brain recovery
│   ├── 10-encryption.sh            # T10: Encryption validation
│   ├── 11-3node-election.sh        # T11: 3-node VRRP election
│   ├── 12-3node-failover.sh        # T12: 3-node failover cascade
│   ├── 13-3node-sync.sh            # T13: 3-node config/lease sync
│   ├── 14-ipv6-vip.sh              # T14: IPv6 VIP support
│   ├── 15-ipv6-lease-sync.sh       # T15: IPv6 lease sync (DHCPv6) + IA_TA + crash recovery
│   ├── 16-ipv6-slaac-mode.sh       # T16: IPv6 SLAAC mode validation
│   ├── 17-ipv6-network-partition.sh # T17: Network partition & split-brain
│   ├── 18-ipv6-hybrid-dhcp.sh      # T18: Hybrid odhcpd/dnsmasq configuration
│   └── 19-ipv6-stress.sh           # T19: IPv6 stress test (1000+ leases)
│
├── lib/
│   ├── common.sh                   # Core test utilities
│   ├── assertions.sh               # Test assertions
│   └── cluster-utils.sh            # Cluster helpers
│
├── scripts/
│   ├── setup.sh                    # Build and start cluster
│   ├── run-tests.sh                # Execute test suite
│   └── teardown.sh                 # Cleanup
│
├── packages/                       # Pre-built .ipk files (gitignored)
├── images/                         # OpenWrt rootfs (gitignored)
├── data/                           # Runtime state (gitignored)
├── logs/                           # Test logs (gitignored)
├── package.json                    # Node.js deps (Playwright for screenshots)
└── node_modules/                   # npm dependencies (gitignored)
```

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│               HA Backend Network (172.30.0.0/24)            │
│                                                             │
│   ┌─────────────┐                    ┌─────────────┐        │
│   │   node1     │◄──────────────────►│   node2     │        │
│   │ 172.30.0.10 │    VRRP/owsync     │ 172.30.0.11 │        │
│   │  MASTER     │    lease-sync      │  BACKUP     │        │
│   └──────┬──────┘                    └──────┬──────┘        │
└──────────┼──────────────────────────────────┼───────────────┘
           │                                  │
┌──────────┼──────────────────────────────────┼───────────────┐
│   ┌──────┴──────┐                    ┌──────┴──────┐        │
│   │192.168.50.10│                    │192.168.50.11│        │
│   └─────────────┘                    └─────────────┘        │
│          │                                  │               │
│          └─── VIP: 192.168.50.254 (floats) ─┘               │
│                                                             │
│   ┌─────────────┐    ┌─────────────┐                        │
│   │  client1    │    │  client2    │                        │
│   │  (DHCP)     │    │  (DHCP)     │                        │
│   └─────────────┘    └─────────────┘                        │
│                                                             │
│              Client LAN (192.168.50.0/24)                   │
└─────────────────────────────────────────────────────────────┘
```

## Container Architecture

### Design Goals

The test containers aim to emulate real OpenWrt router behavior as closely as possible:

1. **procd as PID 1** - Matches real OpenWrt where procd is the init system
2. **Service management via init scripts** - Uses `/etc/init.d/` scripts like real OpenWrt
3. **UCI configuration** - Same configuration system as production
4. **Firewall (fw4/nftables)** - Real OpenWrt firewall stack

### Container Lifecycle Stages

The container goes through 5 distinct stages to reach a "running OpenWrt" state:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ STAGE 1: IMAGE BUILD (Containerfile.node)                                   │
│ ─────────────────────────────────────────                                   │
│ • FROM scratch + OpenWrt rootfs tarball                                     │
│ • opkg install: keepalived, HA packages                                     │
│ • Disable DNSSEC, procd jail                                                │
│ • Copy entrypoint.sh into image                                             │
│ Output: ha-cluster-node:latest image                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ STAGE 2: CONTAINER INSTANTIATION (docker-compose.yml)                       │
│ ─────────────────────────────────────────────────────                       │
│ • Create container from image with:                                         │
│   - Privileged mode + NET_ADMIN, NET_RAW, SYS_ADMIN                         │
│   - Two networks: ha-backend (172.30.0.x), ha-client (192.168.50.x)         │
│   - Volume mounts: /mnt/config (UCI configs), /var/lib, /var/log            │
│   - Environment vars: NODE_NAME, PEER_IP, VIP_ADDRESS, etc.                 │
│   - Sysctls: ip_forward=1, ip_nonlocal_bind=1                               │
│ Output: Container created but not yet running                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ STAGE 3: CONTAINER STARTUP (entrypoint.sh)                                  │
│ ────────────────────────────────────────────                                │
│ • Copy mounted configs from /mnt/config → /etc/config                       │
│ • Start ubusd (message bus - procd needs it)                                │
│ • Wait for network interfaces to get IPs from Docker/Podman                 │
│ • Rename interfaces: eth→lan, eth→backend (based on subnet detection)       │
│ • Enable/disable services for procd boot sequence                           │
│ • exec /sbin/procd (becomes PID 1, runs OpenWrt boot sequence)              │
│ Output: Container running with procd as PID 1, core services starting       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ STAGE 4: NODE CONFIGURATION (setup.sh - configure_nodes)                    │
│ ───────────────────────────────────────────────────────                     │
│ • Read env vars from container (NODE_NAME, PEER_IP, etc.)                   │
│ • Apply UCI configuration via uci set commands                              │
│ • Configure ha-cluster: VIP, peers, services, encryption key                │
│ • Configure dnsmasq: interface, DHCP pool                                   │
│ Output: UCI config files in /etc/config/ populated                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│ STAGE 5: SERVICE STARTUP (setup.sh - start_services)                        │
│ ─────────────────────────────────────────────────────                       │
│ • Start dnsmasq via /etc/init.d/dnsmasq start                               │
│ • Start ha-cluster via /etc/init.d/ha-cluster start                         │
│   - Generates keepalived.conf in /tmp                                       │
│   - Starts keepalived, owsync, lease-sync as procd instances                │
│ Output: Fully operational HA cluster node                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why procd as PID 1?

procd behaves **fundamentally differently** when running as PID 1 vs as a child process:

| Aspect | procd as PID 1 | procd as child |
|--------|----------------|----------------|
| Zombie reaping | ✅ Handles SIGCHLD | ❌ No reaping |
| Service management | ✅ Full boot sequence | ❌ Service manager only |
| Hotplug subsystem | ✅ Properly registered | ⚠️ May not work |
| Shutdown | ✅ Graceful via states | ❌ Container kill |

Without procd as PID 1, orphaned processes become zombies because the placeholder
process (e.g., `tail -f /dev/null`) doesn't implement `wait()` to reap children.

### Container vs Real OpenWrt

| Feature/Behavior | Real OpenWrt | Container | Representative? |
|------------------|--------------|-----------|-----------------|
| **Init System** | procd as PID 1 | procd as PID 1 | ✅ Yes |
| **Process Reaping** | Automatic (PID 1) | Automatic (PID 1) | ✅ Yes |
| **Service Management** | procd init scripts | procd init scripts | ✅ Yes |
| **ubus Communication** | Native | Native | ✅ Yes |
| **Network Stack** | Full kernel | Full kernel (privileged) | ✅ Yes |
| **VRRP (keepalived)** | Multicast on interface | Multicast on interface | ✅ Yes |
| **VIP Assignment** | ip addr add | ip addr add | ✅ Yes |
| **UCI Configuration** | /etc/config/* | /etc/config/* | ✅ Yes |
| **hotplug Events** | Full procd hotplug | procd hotplug | ✅ Yes |
| **Firewall (fw4)** | nftables | nftables | ✅ Yes |
| **File Persistence** | Flash/overlay | Volume mounts | ⚠️ Partial |
| **Boot Sequence** | /etc/rc.d/* | procd boot | ✅ Yes |
| **Package Installation** | opkg at runtime | opkg at image build | ⚠️ Partial |
| **Syslog** | logd/logread | logd/logread | ✅ Yes |
| **Watchdog** | Hardware watchdog | None | ❌ No |

### Role of Input Files

#### Configuration Files (mounted at /mnt/config)

| File | Purpose | Applied When |
|------|---------|--------------|
| `configs/node1/ha-cluster` | Node 1 HA cluster UCI config | Stage 3 (entrypoint copies) |
| `configs/node1/network` | Node 1 network interfaces | Stage 3 |
| `configs/node1/firewall` | Node 1 firewall zones | Stage 3 |
| `configs/node1/dhcp` | Node 1 DHCP/DNS config | Stage 3 |
| `configs/shared/encryption.key` | Shared PSK for owsync/lease-sync | Stage 3 |

**Flow:** `/mnt/config/*` → (entrypoint.sh cp) → `/etc/config/*`

**Note:** Stage 4 (`configure_node_from_env`) overwrites some UCI config with values
from environment variables, allowing dynamic configuration without rebuilding images.

#### Scripts

| Script | Location | Stage | Purpose |
|--------|----------|-------|---------|
| `entrypoint.sh` | In image at / | Stage 3 | Initialize container, exec procd |
| `setup.sh` | Host, runs via exec | Stage 4-5 | Configure UCI, start HA services |
| `run-tests.sh` | Host | After Stage 5 | Execute test scenarios |
| `teardown.sh` | Host | Cleanup | Stop containers, clean volumes |

#### Packages (copied during image build)

| Package | Purpose |
|---------|---------|
| `dnsmasq-ha_*.ipk` | Patched dnsmasq with add_lease/delete_lease ubus |
| `lease-sync_*.ipk` | DHCP lease synchronization daemon |
| `owsync_*.ipk` | Configuration file synchronization daemon |
| `ha-cluster_*.ipk` | Orchestrator scripts (ha-cluster.sh, init, notify) |
| `luci-app-ha-cluster_*.ipk` | Web UI (not used in tests) |
| `keepalived` | From OpenWrt feeds (installed via opkg) |

#### Environment Variables (from docker-compose.yml)

| Variable | Example | Used By |
|----------|---------|---------|
| `NODE_NAME` | ha-node1 | setup.sh (UCI config) |
| `NODE_PRIORITY` | 200 | setup.sh (VRRP priority) |
| `PEER_IP` | 172.30.0.11 | setup.sh (peer address) |
| `PEER_IP6` | fd00:172:30::11 | setup.sh (IPv6 peer address) |
| `VIP_ADDRESS` | 192.168.50.254 | setup.sh (virtual IP) |
| `VIP_NETMASK` | 255.255.255.0 | setup.sh (VIP netmask) |
| `VIP6_ADDRESS` | fd00:192:168:50::254 | setup.sh (IPv6 virtual IP) |
| `VIP6_PREFIX` | 64 | setup.sh (IPv6 prefix length) |

### Interface Renaming

Docker/Podman attach networks in non-deterministic order, causing eth0/eth1 to be
swapped between container restarts. The entrypoint handles this by:

1. Waiting for interfaces to get IPs from Docker/Podman
2. Detecting which interface has which subnet (by IP address)
3. Renaming to logical names: `eth*` → `lan` (192.168.50.x), `eth*` → `backend` (172.30.0.x)

This ensures consistent interface names regardless of attachment order.

### Firewall Configuration

The containers use OpenWrt's fw4 firewall. Both `lan` and `backend` interfaces
are placed in the same `lan` zone (trusted internal networks):

```
config zone 'lan'
    option name 'lan'
    list network 'lan'
    list network 'backend'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
```

Without this configuration, fw4's default `policy drop` blocks inter-container traffic.

## Test Scenarios

### Priority 1 - Core Functionality (T01-T05)

| ID | Scenario | Validates |
|----|----------|-----------|
| T01 | Basic Startup | All services start, ubus available |
| T02 | VRRP Election | Correct MASTER/BACKUP assignment |
| T03 | VIP Failover | VIP migrates on MASTER failure |
| T04 | Config Sync | owsync replicates UCI changes |
| T05 | Lease Sync | lease-sync replicates DHCP leases |

### Priority 2 - Reliability & Robustness (T06-T10)

| ID | Scenario | Validates |
|----|----------|-----------|
| T06 | Service Recovery | procd respawns crashed services (keepalived, owsync, lease-sync) |
| T07 | Startup Reconciliation | Stale leases deleted when lease-sync restarts |
| T08 | Injection Retry Queue | Lease injection retries when dnsmasq unavailable |
| T09 | Network Partition | Cluster reconverges after split-brain |
| T10 | Encryption | AES-256-GCM encryption active, no plaintext in traffic |

### Priority 3 - Multi-Node (T11-T13)

| ID | Scenario | Validates |
|----|----------|-----------|
| T11 | 3-Node Election | Correct MASTER/BACKUP assignment in 3-node cluster |
| T12 | 3-Node Failover | VIP cascade through all nodes (MASTER→Secondary→Tertiary) |
| T13 | 3-Node Sync | Config and lease sync across all 3 nodes in mesh |

**Note:** T11-T13 require a 3-node cluster. Start with:
```bash
./scripts/setup.sh --3node
```

### Priority 4 - IPv6 (T14-T16)

| ID | Scenario | Validates |
|----|----------|-----------|
| T14 | IPv6 VIP | IPv6 VIP assignment and failover |
| T15 | IPv6 Lease Sync | DHCPv6 lease sync, IAID/is_temporary field handling |
| T16 | IPv6 SLAAC Mode | SLAAC works without lease sync (VIP failover sufficient) |

**Note:** T14-T16 run on the default dual-stack cluster.
- T15 requires stateful DHCPv6 mode (test config default)
- T16 temporarily enables SLAAC mode during test
- All tests verify odhcpd is absent/disabled (lease-sync requires dnsmasq)

**IPv6 Configuration:**
- Docker daemon may need IPv6 enabled in `/etc/docker/daemon.json`:
  ```json
  { "ipv6": true, "fixed-cidr-v6": "fd00::/8" }
  ```
- Podman users: The setup script automatically detects and works around podman/netavark IPv6 assignment issues. No manual intervention required.

## Usage

### Run All Priority 1 Tests

```bash
./scripts/run-tests.sh
```

### Run Specific Test

```bash
./scripts/run-tests.sh 03-vrrp-failover
./scripts/run-tests.sh 01 02 03    # Multiple tests
```

### Run All Tests

```bash
./scripts/run-tests.sh --all
```

### List Available Tests

```bash
./scripts/run-tests.sh --list
```

### 3-Node Cluster

```bash
./scripts/setup.sh --3node
./scripts/run-tests.sh
```

### Interactive Access

```bash
# Access node shells
podman exec -it ha-node1 sh
podman exec -it ha-node2 sh

# View logs
podman logs ha-node1
podman logs ha-node2
```

### Cleanup

```bash
# Stop containers, keep data
./scripts/teardown.sh

# Stop containers, remove data
./scripts/teardown.sh --clean

# Remove everything including images
./scripts/teardown.sh --full
```

## Test Framework

The test framework in `lib/` provides:

### common.sh
- Color output (`pass`, `fail`, `skip`, `info`)
- Test counters and summary
- Container runtime detection
- Timeout utilities (`wait_for`)

### assertions.sh
- Basic assertions (`assert_eq`, `assert_contains`)
- File assertions (`assert_file_exists`)
- Process assertions (`assert_process_running`)
- Network assertions (`assert_ping`, `assert_port_open`)

### cluster-utils.sh
- Container execution (`exec_node`, `exec_node1`)
- VRRP state helpers (`get_vrrp_state`, `has_vip`, `get_vip_owner`)
- Service management (`service_running`, `service_start`, `service_stop`)
- Lease management (`add_lease`, `delete_lease`, `lease_exists`)
- UCI helpers (`uci_get`, `uci_set`)
- Sync utilities (`trigger_owsync`, `wait_for_file`)
- Process management (`kill_process`, `wait_for_respawn`)
- Network partition (`create_network_partition`, `heal_network_partition`)
- Traffic capture (`capture_traffic`, `verify_no_plaintext`)
- Advanced lease helpers (`get_all_leases`, `inject_lease_directly`)

### Writing New Tests

```sh
#!/bin/sh
# Load test framework
. "$TEST_DIR/lib/common.sh"
. "$TEST_DIR/lib/assertions.sh"
. "$TEST_DIR/lib/cluster-utils.sh"

test_example() {
    subheader "Example Test"

    if service_running "$NODE1" "keepalived"; then
        pass "keepalived running"
    else
        fail "keepalived not running"
        return 1
    fi
}

main() {
    header "Example Test Suite"
    test_example || return 1
    return 0
}

main
exit $?
```

## CI Integration

### GitHub Actions (Non-Privileged)

Tests that don't require VRRP (T04, T05) can run without privileged mode:

```yaml
- name: Run non-VRRP tests
  run: |
    ./scripts/setup.sh --skip-vrrp
    ./scripts/run-tests.sh 04-config-sync 05-lease-sync
```

### Self-Hosted Runner (Full HA)

For complete testing including VRRP failover:

1. Set up a self-hosted runner with Docker/Podman
2. Enable privileged container support
3. Run full test suite

## Troubleshooting

### Containers won't start

```bash
# Check for port conflicts
podman ps -a

# View container logs
podman logs ha-node1

# Try manual start
podman run --rm -it ha-cluster-node:latest sh
```

### VRRP not working

```bash
# Check keepalived config
podman exec ha-node1 cat /tmp/keepalived.conf

# Check keepalived logs
podman exec ha-node1 logread | grep keepalived

# Verify network connectivity
podman exec ha-node1 ping -c 1 172.30.0.11
```

### Sync not working

```bash
# Check owsync status
podman exec ha-node1 ps | grep owsync
podman exec ha-node1 logread | grep owsync

# Check lease-sync status
podman exec ha-node1 ps | grep lease-sync
podman exec ha-node1 logread | grep lease-sync
```

### Test failures

```bash
# Run with verbose output
DEBUG=1 ./scripts/run-tests.sh -v

# Check individual test
./scripts/run-tests.sh 01-basic-startup

# Inspect cluster state
podman exec ha-node1 /usr/libexec/rpcd/ha-cluster call status
```

### IPv6 addresses not assigned

If nodes don't have IPv6 addresses after setup:

**Symptoms:**
```bash
podman exec ha-node1 ip -6 addr show scope global
# No output (should show fd00: addresses)
```

**Root Cause:** Podman/netavark IPv6 configuration bug - addresses are assigned in the network config but not applied to container interfaces.

**Solution:** The setup script automatically detects this and applies a workaround. If you see:
```
=========================================
IPv6 Workaround Required
=========================================
```

The script will manually add IPv6 addresses to each interface. This is automatic and requires no user intervention.

**Verify workaround:**
```bash
podman exec ha-node1 ip -6 addr show scope global
# Should show: fd00:172:30::10/64 on backend, fd00:192:168:50::10/64 on lan
```

### Outdated packages

If tests fail with unexpected behavior (especially T05 lease sync), packages may be outdated.

**Check package build date:**
```bash
ls -la packages/*.ipk
```

**Verify binary matches source code:**
```bash
# Check lease-sync event pattern (should be "dhcp.lease" not "dhcp.lease.*")
podman exec ha-node1 strings /usr/sbin/lease-sync | grep "dhcp.lease"
```

**Fix: Rebuild packages and images:**
```bash
# Rebuild packages from source (see Prerequisites section)
# Then force rebuild images
./scripts/teardown.sh --full
./scripts/setup.sh --force-rebuild
```

## Screenshots

A headless browser screenshot tool is available for capturing LuCI pages during manual testing.

### Setup

```bash
cd tests
npm install                       # Installs Playwright
npx playwright install chromium   # Downloads bundled Chromium (~170 MB, one-time)
```

### Usage

```bash
# Capture a LuCI page
../scripts/screenshot.sh http://192.168.50.254/cgi-bin/luci/ luci-home.png

# Capture the HA status page
../scripts/screenshot.sh http://172.30.0.10/cgi-bin/luci/admin/services/ha-cluster ha-status.png
```

The script uses Playwright with a headless Chromium browser (1280x720 viewport, full-page capture).

## Related Documentation

- [ha-cluster Design](../ha-cluster/README.md) - Architecture and configuration
- [LuCI Application](../luci-app-ha-cluster/README.md) - Web interface documentation

## License

GPL-2.0-or-later
The test infrastructure has been developed using Claude Code from Anthropic.

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
