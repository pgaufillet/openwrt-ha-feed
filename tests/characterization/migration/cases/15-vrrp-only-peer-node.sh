# Running node whose only peer is VRRP-only (sync_enabled 0): the peer
# becomes vrrp_only, file and lease sync settings are kept
cat > /etc/config/ha-cluster <<'CONF'
config global 'config'
	option enabled '1'
	option vrrp_transport 'multicast'
	option sync_method 'owsync'
	option encryption_key '7f8e9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e'

config vrrp_instance 'main'
	option vrid '51'
	option interface 'lan'
	option priority '200'
	option nopreempt '0'

config vip 'lan'
	option enabled '1'
	option vrrp_instance 'main'
	option interface 'lan'
	option address '192.168.50.254'
	option netmask '255.255.255.0'

config peer 'router'
	option name 'isp-router'
	option address '192.168.50.1'
	option sync_enabled '0'

config service 'dhcp'
	option enabled '1'
	option sync_leases '1'
	list config_files 'dhcp'

config exclude
	list file 'network'
	list file 'system'
	list file 'owsync'
	list file 'ha-cluster'
CONF
