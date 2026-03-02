#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

[ -f "$USER_DHCPSCRIPT" ] && . "$USER_DHCPSCRIPT" "$@"

. /usr/share/libubox/jshn.sh

json_init
json_add_array env
hotplugobj=""

case "$1" in
	add | del | old | arp-add | arp-del)
		json_add_string "" "MACADDR=$2"
		json_add_string "" "IPADDR=$3"
	;;
esac

case "$1" in
	add)
		json_add_string "" "ACTION=add"
		json_add_string "" "HOSTNAME=$4"
		# Forward dnsmasq lease info (critical for lease-sync)
		[ -n "$DNSMASQ_LEASE_EXPIRES" ] && json_add_string "" "DNSMASQ_LEASE_EXPIRES=$DNSMASQ_LEASE_EXPIRES"
		[ -n "$DNSMASQ_TIME_REMAINING" ] && json_add_string "" "DNSMASQ_TIME_REMAINING=$DNSMASQ_TIME_REMAINING"
		[ -n "$DNSMASQ_LEASE_LENGTH" ] && json_add_string "" "DNSMASQ_LEASE_LENGTH=$DNSMASQ_LEASE_LENGTH"
		[ -n "$DNSMASQ_CLIENT_ID" ] && json_add_string "" "DNSMASQ_CLIENT_ID=$DNSMASQ_CLIENT_ID"
		[ -n "$DNSMASQ_INTERFACE" ] && json_add_string "" "DNSMASQ_INTERFACE=$DNSMASQ_INTERFACE"
		[ -n "$DNSMASQ_IAID" ] && json_add_string "" "DNSMASQ_IAID=$DNSMASQ_IAID"
		hotplugobj="dhcp"
	;;
	del)
		json_add_string "" "ACTION=remove"
		json_add_string "" "HOSTNAME=$4"
		hotplugobj="dhcp"
	;;
	old)
		json_add_string "" "ACTION=update"
		json_add_string "" "HOSTNAME=$4"
		# Forward dnsmasq lease info (critical for lease-sync)
		[ -n "$DNSMASQ_LEASE_EXPIRES" ] && json_add_string "" "DNSMASQ_LEASE_EXPIRES=$DNSMASQ_LEASE_EXPIRES"
		[ -n "$DNSMASQ_TIME_REMAINING" ] && json_add_string "" "DNSMASQ_TIME_REMAINING=$DNSMASQ_TIME_REMAINING"
		[ -n "$DNSMASQ_LEASE_LENGTH" ] && json_add_string "" "DNSMASQ_LEASE_LENGTH=$DNSMASQ_LEASE_LENGTH"
		[ -n "$DNSMASQ_CLIENT_ID" ] && json_add_string "" "DNSMASQ_CLIENT_ID=$DNSMASQ_CLIENT_ID"
		[ -n "$DNSMASQ_INTERFACE" ] && json_add_string "" "DNSMASQ_INTERFACE=$DNSMASQ_INTERFACE"
		[ -n "$DNSMASQ_IAID" ] && json_add_string "" "DNSMASQ_IAID=$DNSMASQ_IAID"
		hotplugobj="dhcp"
	;;
	arp-add)
		json_add_string "" "ACTION=add"
		hotplugobj="neigh"
	;;
	arp-del)
		json_add_string "" "ACTION=remove"
		hotplugobj="neigh"
	;;
	tftp)
		json_add_string "" "ACTION=add"
		json_add_string "" "TFTP_SIZE=$2"
		json_add_string "" "TFTP_ADDR=$3"
		json_add_string "" "TFTP_PATH=$4"
		hotplugobj="tftp"
	;;
esac

json_close_array env

[ -n "$hotplugobj" ] && ubus call hotplug.${hotplugobj} call "$(json_dump)"
