# Containerised build environment

This directory provides a Docker image that compiles the ha-cluster feed
packages using the **official OpenWrt SDK**. The SDK ships a prebuilt
cross-toolchain, so packages build in a few minutes without cloning a full
OpenWrt buildroot or rebuilding the toolchain.

Use this when you want ready-to-install packages without setting up a
build host by hand — build on any machine with Docker, then copy the packages
to your routers or host them on a signed feed.

## Requirements

- Docker (or a compatible runtime such as Podman)
- Network access at build time (to fetch the SDK and package sources)

## Quick start

Build the image for the default target (x86-64) and compile every package:

```bash
# From the repository root
docker build -t ha-feed-build docker/
docker run --rm -v "$PWD/output:/output" ha-feed-build
```

The built packages land in `./output/<arch>/ha_feed/` on the host, mirroring
the SDK's `bin/packages/` layout. The file format follows the target release:
`.apk` on 25.12 and later, `.ipk` on 24.10 and earlier.

> **Rootless Podman users:** add `--userns=keep-id` so the container can write
> to the mounted output directory, e.g.
> `podman run --rm --userns=keep-id -v "$PWD/output:/output" ha-feed-build`
> (or use the `:U` mount flag). Plain Docker needs no extra flag when the host
> directory is writable by UID 1000.

## Choosing a target

The image is target-specific: the packages must match your router's
architecture. Pass `--build-arg OPENWRT_TARGET=<target>/<subtarget>` using the
same names as the [OpenWrt download tree](https://downloads.openwrt.org/releases/).

| Router example | `OPENWRT_TARGET` |
|----------------|------------------|
| x86-64 (VM, PC) | `x86/64` (default) |
| MediaTek Filogic (aarch64) | `mediatek/filogic` |
| MT7621 (ramips) | `ramips/mt7621` |
| ath79 generic | `ath79/generic` |

```bash
docker build -t ha-feed-build-filogic \
  --build-arg OPENWRT_TARGET=mediatek/filogic docker/
docker run --rm -v "$PWD/output:/output" ha-feed-build-filogic
```

## Choosing an OpenWrt version

The image is built for release `25.12.0` by default. Pass `--build-arg
OPENWRT_VERSION=<version>` to target another release — use the bare version
number (as it appears under
[`releases/`](https://downloads.openwrt.org/releases/)), **without** a `v`
prefix:

```bash
# Filogic packages for OpenWrt 24.10.8
docker build -t ha-feed-build-filogic-2410 \
  --build-arg OPENWRT_VERSION=24.10.8 \
  --build-arg OPENWRT_TARGET=mediatek/filogic \
  docker/
docker run --rm -v "$PWD/output:/output" ha-feed-build-filogic-2410
```

The exact SDK (including its toolchain version, which differs between releases)
is discovered automatically from the target's `sha256sums` index and verified
against its published checksum, so any valid `OPENWRT_VERSION` ×
`OPENWRT_TARGET` combination resolves without extra flags. Only stable
`releases/` are supported (not `snapshots/`).

## Which version to build against

A package encodes the shared-library versions of the SDK it was built with, so
it may fail to install on an older point release of the same branch
(`libX.so.N: No such file or directory`).

- **Building for one device:** match its exact release. Simplest and safest.
- **Reusing the same package across several devices** on one branch at
  different point releases: build against the **earliest** point release you
  target (`24.10.0`, `25.12.0`, ...). Linking against the oldest library set
  maximises install compatibility across the branch.
- **`dnsmasq-ha`** replaces the core `dnsmasq` and is more tightly coupled to
  its release than the userspace packages — prefer a per-release build for it.

## Building a subset of packages

Pass package names as arguments to `docker run`:

```bash
docker run --rm -v "$PWD/output:/output" ha-feed-build owsync lease-sync
```

Available packages: `dnsmasq-ha`, `owsync`, `lease-sync`, `ha-cluster`,
`luci-app-ha-cluster`.

## Signing a package index

To produce a signed feed index (so routers can update from an HTTP
server), mount a [usign](https://openwrt.org/docs/guide-user/security/keygen)
private key and set `SIGN_KEY`:

```bash
docker run --rm \
  -v "$PWD/output:/output" \
  -v "$PWD/keys/ha_feed.sec:/keys/ha_feed.sec:ro" \
  -e SIGN_KEY=/keys/ha_feed.sec \
  ha-feed-build
```

`Packages`, `Packages.gz`, `Packages.sig` and `index.json` are copied into
`./output` alongside the packages. See the "Building and Hosting Your Own
Package Repository" section of the top-level [README](../README.md) for how to
deploy and consume the signed feed.

## Building from a local checkout

By default the image fetches the feed from the public GitHub repository, so it
reproduces the released packages independently. To build your local working
copy instead (including uncommitted changes), bind-mount it and point the feed
at it:

```bash
docker build -t ha-feed-build-local \
  --build-arg HA_FEED_SRC="src-link ha_feed /feed" docker/
docker run --rm \
  -v "$PWD:/feed:ro" \
  -v "$PWD/output:/output" \
  ha-feed-build-local
```

## Other options

| Variable | Purpose |
|----------|---------|
| `JOBS` | Parallel build jobs (default: number of CPUs). `-e JOBS=4` |
| `VERBOSE` | `-e VERBOSE=1` for `make ... V=s` verbose output |

## How it works

1. **Dockerfile** — Debian base + OpenWrt build dependencies, downloads and
   unpacks the SDK, and appends `ha_feed` to `feeds.conf`.
2. **build-packages.sh** (entrypoint) — updates/installs feeds, runs
   `make package/<pkg>/compile`, optionally signs the index, and copies the
   artifacts to the mounted `/output` directory.
