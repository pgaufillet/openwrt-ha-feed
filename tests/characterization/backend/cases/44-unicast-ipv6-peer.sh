# Unicast over IPv6 with an IPv4 VIP only: one IPv6 instance advertising
# no VIP, the IPv4 VIP excluded
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.address=fd00:30::11
uci set ha-cluster.peer1.source_address=fd00:30::10
