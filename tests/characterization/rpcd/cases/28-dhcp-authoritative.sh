# dnsmasq authoritative while dhcp is synced and lease sync is on
uci set dhcp.@dnsmasq[0].authoritative=1
