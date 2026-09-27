# VIP without an enabled option, DHCP force missing on its interface
uci delete ha-cluster.lan.enabled
uci delete dhcp.lan.force
