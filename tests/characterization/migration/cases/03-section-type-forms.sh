# Every spelling of the service type is renamed, lookalikes are not;
# no option changes, so uci keeps the comments
cat > /etc/config/ha-cluster <<'CONF'
# leading comment
config config 'config'
	option enabled '1'

config service 'dhcp'
	list config_files 'dhcp'

config 'service' 'firewall'
	list config_files 'firewall'

config "service" "wifi"
	list config_files 'wireless'

  config	service
	list config_files 'system'

config service
	list config_files 'uhttpd'

config peer 'service'
	option name 'service'
	option address '172.30.0.11'

config services 'other'
	option note 'config service'

#config service 'commented'
CONF
