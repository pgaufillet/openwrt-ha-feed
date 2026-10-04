# dnsmasq authoritative, lease sync off, dhcp group disabled and dhcp
# listed by another group: no warning; none either once the dhcp group
# is deleted
uci set ha-cluster.dhcp.sync_leases=0
uci set ha-cluster.dhcp.enabled=0
uci set ha-cluster.shared=service
uci add_list ha-cluster.shared.config_files=dhcp
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci delete ha-cluster.dhcp
}
