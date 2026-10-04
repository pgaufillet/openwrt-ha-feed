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

To produce a signed package index (so routers can update from an HTTP
server), mount the private signing key and set `SIGN_KEY`. On 25.12 and
later the key is an apk ECDSA key (see the top-level README for how to
generate it):

```bash
docker run --rm \
  -v "$PWD/output:/output" \
  -v "$PWD/keys/ha_feed_apk.sec:/keys/ha_feed_apk.sec:ro" \
  -e SIGN_KEY=/keys/ha_feed_apk.sec \
  ha-feed-build
```

The signed index `packages.adb` (and `index.json`) is copied into
`./output` alongside the packages. On 24.10 and earlier, `SIGN_KEY` is a
[usign](https://openwrt.org/docs/guide-user/security/keygen) private key
and the index files are `Packages`, `Packages.gz`, `Packages.sig` and
`index.json`. See the "Building and Hosting Your Own Package Repository"
section of the top-level [README](../README.md) for how to deploy and
consume the signed feed.

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

## Faster repeated builds

Each `docker run --rm` starts from the bare SDK and rebuilds every dependency
of the requested packages. To keep the SDK state (downloads, build and staging
directories) between runs, mount a named volume on the SDK directory; it is
seeded from the image on first use, and later runs only rebuild what changed:

```bash
docker run --rm \
  -v ha-feed-sdk:/home/build/openwrt-sdk \
  -v "$PWD:/feed:ro" \
  -v "$PWD/output:/output" \
  ha-feed-build-local ha-cluster
```

Combined with a local checkout (previous section), edits to the feed are
picked up on the next run. In this mode the requested packages are always
rebuilt, and only they are copied to `./output` (not their dependencies).

- Use a named volume, not a host directory: only named volumes are seeded.
- Prefer a one-shot build for releases: with `SIGN_KEY`, the index covers
  every package the volume holds, including those of earlier runs.
- Use one volume per image. After rebuilding the image, the old volume is
  rejected; clear it with `docker volume rm ha-feed-sdk` (the next run
  reseeds it).
- Run one build at a time per volume.

## Other options

| Variable | Purpose |
|----------|---------|
| `JOBS` | Parallel build jobs (default: number of CPUs). `-e JOBS=4` |
| `VERBOSE` | `-e VERBOSE=1` for `make ... V=s` verbose output |

## How it works

1. **Dockerfile** — Debian base + OpenWrt build dependencies, downloads and
   unpacks the SDK, fetches its (pinned) upstream feeds, and appends
   `ha_feed` to `feeds.conf`.
2. **build-packages.sh** (entrypoint) — updates `ha_feed`, installs the
   requested packages, selects only them and their dependencies, compiles
   them in parallel, optionally signs the index, and copies the artifacts to
   the mounted `/output` directory.
