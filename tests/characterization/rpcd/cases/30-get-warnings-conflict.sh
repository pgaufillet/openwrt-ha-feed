# Warnings: dnsmasq authoritative while dhcp is synced and lease sync is on
RPCD_METHOD=get_warnings
uci set dhcp.@dnsmasq[0].authoritative=1
