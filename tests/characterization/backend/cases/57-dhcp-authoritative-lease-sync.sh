# dnsmasq authoritative, dhcp not synced, lease sync on: warning, none
# once lease sync is off
uci delete ha-cluster.dhcp.config_files
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci set ha-cluster.config.lease_sync=0
}
