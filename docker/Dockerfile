# OpenWrt HA Cluster feed - containerised build environment
#
# Copyright (C) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Builds the ha-cluster feed packages using the official OpenWrt SDK.
# The SDK ships a prebuilt cross-toolchain, so packages compile in minutes
# without rebuilding the whole toolchain (unlike a full buildroot clone).
#
# Build the image for the default target (x86-64):
#   docker build -t ha-feed-build docker/
#
# Build for a different target (e.g. MediaTek Filogic / aarch64):
#   docker build -t ha-feed-build-filogic \
#     --build-arg OPENWRT_TARGET=mediatek/filogic docker/
#
# Compile all packages, dropping .apk files into ./output on the host:
#   docker run --rm -v "$PWD/output:/output" ha-feed-build
#
# See docker/README.md for the full guide (signing, custom feed source, etc.).

FROM debian:bookworm-slim

# --- Build arguments ---------------------------------------------------------
# OpenWrt release the SDK is taken from. Must match the firmware on the router.
ARG OPENWRT_VERSION=25.12.0
# Target/subtarget as used in the OpenWrt download tree (target/subtarget).
# Examples: x86/64, mediatek/filogic, ath79/generic, ramips/mt7621
ARG OPENWRT_TARGET=x86/64
# Feed source. Defaults to the public repository so the image is self-contained.
# Override with a fork/branch, or bind-mount a local checkout at /feed and pass
# HA_FEED_SRC="src-link ha_feed /feed".
ARG HA_FEED_SRC="src-git ha_feed https://github.com/pgaufillet/openwrt-ha-feed.git"

# --- Host build dependencies -------------------------------------------------
# Package list follows the OpenWrt "build system setup" docs (Debian), plus
# zstd for the .tar.zst SDK archive.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        file \
        gawk \
        gettext \
        git \
        libncurses-dev \
        libssl-dev \
        python3 \
        python3-distutils-extra \
        rsync \
        unzip \
        wget \
        xsltproc \
        xz-utils \
        zlib1g-dev \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# The OpenWrt SDK refuses to run as root. Create an unprivileged build user.
RUN useradd -m -s /bin/bash build
USER build
WORKDIR /home/build

# --- Download and unpack the SDK ---------------------------------------------
# The SDK tarball name embeds the toolchain version (e.g. gcc-14.3.0_musl),
# which differs from one OpenWrt release to the next. Rather than hard-code it,
# discover the exact filename (and its checksum) from the target's sha256sums
# index, so any OPENWRT_VERSION x OPENWRT_TARGET combination resolves correctly.
RUN set -eux; \
    base="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}"; \
    echo "Resolving SDK from ${base}/sha256sums"; \
    wget -q "${base}/sha256sums" -O sha256sums; \
    line="$(grep -E 'openwrt-sdk-.*\.Linux-x86_64\.tar\.(zst|xz)' sha256sums | head -n1)"; \
    [ -n "${line}" ] || { echo "ERROR: no SDK listed for ${OPENWRT_VERSION}/${OPENWRT_TARGET}" >&2; exit 1; }; \
    sdk_file="$(printf '%s\n' "${line}" | sed -E 's/^[0-9a-f]+ [ *]//')"; \
    echo "Fetching ${sdk_file}"; \
    wget -q "${base}/${sdk_file}" -O "${sdk_file}"; \
    printf '%s  %s\n' "$(printf '%s\n' "${line}" | awk '{print $1}')" "${sdk_file}" | sha256sum -c -; \
    case "${sdk_file}" in \
        *.tar.zst) tar --use-compress-program=unzstd -xf "${sdk_file}"; sdk_dir="${sdk_file%.tar.zst}" ;; \
        *.tar.xz)  tar -xf "${sdk_file}"; sdk_dir="${sdk_file%.tar.xz}" ;; \
        *) echo "ERROR: unexpected SDK archive ${sdk_file}" >&2; exit 1 ;; \
    esac; \
    rm "${sdk_file}" sha256sums; \
    mv "${sdk_dir}" openwrt-sdk

WORKDIR /home/build/openwrt-sdk

# --- Register the feeds ------------------------------------------------------
# Keep the SDK's default upstream feeds and fetch them now: the SDK pins them
# to fixed revisions, so doing it once here spares every build the download
# and indexing. ha_feed is appended afterwards and updated at build time.
RUN set -eux; \
    cp feeds.conf.default feeds.conf; \
    ./scripts/feeds update -a; \
    echo "${HA_FEED_SRC}" >> feeds.conf

# --- Tag the SDK directory ---------------------------------------------------
# A volume mounted on the SDK directory keeps the copy it was seeded from;
# the entrypoint compares both tags to reject a volume from another image.
RUN cat /proc/sys/kernel/random/uuid | tee .image-id > ../.image-id

# --- Build entrypoint --------------------------------------------------------
COPY --chown=build:build build-packages.sh /home/build/build-packages.sh
ENTRYPOINT ["/home/build/build-packages.sh"]
