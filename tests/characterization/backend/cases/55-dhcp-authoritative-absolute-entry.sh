# dnsmasq authoritative, lease sync off, dhcp listed as an absolute path,
# which owsync never matches: warning, the dhcp group's entries are not
# matched; still one once sync_dir is / and a pattern matches the path
# relative to it
uci set ha-cluster.dhcp.sync_leases=0
uci delete ha-cluster.dhcp.config_files
uci add_list ha-cluster.dhcp.config_files=/etc/config/dhcp
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci set ha-cluster.config.sync_dir=/
	uci delete ha-cluster.dhcp.config_files
	uci add_list ha-cluster.dhcp.config_files='etc/*/dhcp'
}
