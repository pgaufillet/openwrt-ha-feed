# Any sync_method other than owsync turned file sync off, like none
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'
	option sync_method 'rsync'

config service 'dhcp'
	option sync_leases '1'
	list config_files 'dhcp'
CONF
