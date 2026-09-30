# dnsmasq authoritative, lease sync off, dhcp synced through the pattern
# '*': warning; still one with a pattern padded with spaces, which owsync
# trims
uci set ha-cluster.dhcp.sync_leases=0
uci delete ha-cluster.dhcp.config_files
uci add_list ha-cluster.dhcp.config_files='*'
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci delete ha-cluster.dhcp.config_files
	uci add_list ha-cluster.dhcp.config_files=' dhc? '
}
