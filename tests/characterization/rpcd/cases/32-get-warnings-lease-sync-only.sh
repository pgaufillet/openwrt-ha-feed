# Warnings: dnsmasq authoritative, dhcp group disabled, lease sync on
RPCD_METHOD=get_warnings
uci set ha-cluster.dhcp.enabled=0
uci set dhcp.@dnsmasq[0].authoritative=1
