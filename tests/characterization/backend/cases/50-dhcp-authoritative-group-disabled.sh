# dnsmasq authoritative while dhcp is synced, lease sync off: warning,
# none once the dhcp sync group is disabled
uci set ha-cluster.dhcp.sync_leases=0
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci set ha-cluster.dhcp.enabled=0
}
