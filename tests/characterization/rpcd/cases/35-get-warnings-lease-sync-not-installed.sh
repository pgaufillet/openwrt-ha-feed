# Warnings: dnsmasq authoritative while dhcp is synced, lease-sync not
# installed
RPCD_METHOD=get_warnings
rm -f /usr/sbin/lease-sync /etc/init.d/lease-sync
uci set dhcp.@dnsmasq[0].authoritative=1
