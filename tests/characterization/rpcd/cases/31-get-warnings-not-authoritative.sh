# Warnings: dhcp synced and lease sync on, dnsmasq not authoritative
RPCD_METHOD=get_warnings
uci set dhcp.@dnsmasq[0].authoritative=0
