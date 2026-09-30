# Warnings: dnsmasq authoritative, owsync not installed, lease sync on
RPCD_METHOD=get_warnings
rm -f /usr/bin/owsync /etc/init.d/owsync
uci set dhcp.@dnsmasq[0].authoritative=1
