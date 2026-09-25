# dhcp switch "off" becomes lease_sync 0; the switch of another group was
# never read and is dropped
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'

config service 'dhcp'
	option sync_leases 'off'
	list config_files 'dhcp'

config service 'misc'
	option sync_leases '1'
	list config_files 'uhttpd'
CONF
