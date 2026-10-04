# dhcp group listing no file, dhcp listed by another group without
# enabled, second dnsmasq section authoritative, lease sync off: no
# warning, as only the dhcp group counts; none either once no group
# lists dhcp
uci set ha-cluster.dhcp.sync_leases=0
uci delete ha-cluster.dhcp.config_files
uci set ha-cluster.shared=service
uci add_list ha-cluster.shared.config_files=firewall
uci add_list ha-cluster.shared.config_files=dhcp
uci add dhcp dnsmasq
uci set dhcp.@dnsmasq[1].authoritative=yes
STEP2=reload
step2() {
	uci del_list ha-cluster.shared.config_files=dhcp
}
