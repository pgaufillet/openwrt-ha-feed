# Unicast over IPv4 with an IPv6 VIP: one IPv4 instance, the IPv6 VIP
# excluded
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
