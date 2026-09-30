# dnsmasq authoritative, lease sync off, dhcp listed but excluded: no
# warning
uci set ha-cluster.dhcp.sync_leases=0
uci add_list ha-cluster.@exclude[0].file=dhcp
uci set dhcp.@dnsmasq[0].authoritative=1
