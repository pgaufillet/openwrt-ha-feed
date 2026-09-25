# sync_method none: every group disabled, whatever its enabled value,
# anonymous ones included; sync_method removed
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'
	option sync_method 'none'

config service 'dhcp'
	option enabled '1'
	option sync_leases '1'
	list config_files 'dhcp'

config service 'firewall'
	option enabled '0'
	list config_files 'firewall'

config service 'misc'
	list config_files 'uhttpd'

config service
	option enabled 'yes'
	list config_files 'system'
CONF
