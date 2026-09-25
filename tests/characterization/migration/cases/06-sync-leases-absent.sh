# dhcp group without the switch: no lease_sync is written
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'
	option sync_method 'owsync'

config service 'dhcp'
	option enabled '1'
	list config_files 'dhcp'
CONF
