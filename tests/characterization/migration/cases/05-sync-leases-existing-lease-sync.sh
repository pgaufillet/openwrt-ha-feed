# An existing lease_sync wins over the dhcp group switch
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'
	option lease_sync '0'

config service 'dhcp'
	option sync_leases 'true'
	list config_files 'dhcp'
CONF
