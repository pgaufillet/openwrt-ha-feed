# dnsmasq authoritative while dhcp is synced, cluster disabled
uci set ha-cluster.config.enabled=0
uci set dhcp.@dnsmasq[0].authoritative=1
