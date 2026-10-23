# dnsmasq-ha

dnsmasq with ubus lease management patches

## Overview

Replaces the stock dnsmasq with a version adding ubus methods (`add_lease`,
`delete_lease`, `get_leases`) required for HA DHCP lease synchronization.
Cannot be installed alongside dnsmasq or dnsmasq-full.

## Contents

The package follows the stock dnsmasq of the OpenWrt branch the feed
branch follows: same upstream version, same `files/` and same patches 100
and 200. Only the packaging differs: a single variant, built with the
dnsmasq-full default options, which provides `dnsmasq`.

[`patches/300-ubus-add-lease-methods.patch`](patches/300-ubus-add-lease-methods.patch)
adds the lease methods to dnsmasq's ubus object; lease-sync uses them to
replicate leases between nodes.

## Installation

Removing the stock dnsmasq stops the router's DNS resolution, so every
dependency must be installed before the swap. Use the installation script
or the manual steps in the
[ha-cluster README](../ha-cluster/README.md#installation).

## Configuration

Same as the stock dnsmasq (`/etc/config/dhcp`). For lease synchronization,
see the [DHCP prerequisites](../ha-cluster/README.md#dhcp-prerequisites).
