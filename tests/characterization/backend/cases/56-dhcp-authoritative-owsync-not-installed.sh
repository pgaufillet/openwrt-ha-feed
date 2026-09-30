# dnsmasq authoritative, lease sync off, dhcp listed but owsync not
# installed: no warning
rm -f /usr/bin/owsync /etc/init.d/owsync
uci set ha-cluster.dhcp.sync_leases=0
uci set dhcp.@dnsmasq[0].authoritative=1
