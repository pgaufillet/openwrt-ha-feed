# What the LuCI pages call, for a user holding only the luci-base and
# luci-app-ha-cluster ACL groups
checks() {
	access ubus ha-cluster status
	access ubus ha-cluster get_warnings
	access ubus ha-cluster generate_key
	access ubus ha-cluster apply
	access ubus network.interface dump
	access ubus file list
	access ubus file read
	access ubus file stat
	access ubus file write
	access uci ha-cluster read
	access uci ha-cluster write
	file_call stat /usr/bin/owsync
	file_call stat /usr/sbin/lease-sync
	file_call list /etc/hotplug.d/keepalived
	file_call read /etc/hotplug.d/keepalived/01-ubus
	file_call write /etc/hotplug.d/keepalived/99-char '"data":"#!/bin/sh\n"'
}
