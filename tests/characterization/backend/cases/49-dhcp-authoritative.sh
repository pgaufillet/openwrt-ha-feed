# dnsmasq authoritative while dhcp is synced: warning, none once it is
# no longer authoritative
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci set dhcp.@dnsmasq[0].authoritative=0
}
