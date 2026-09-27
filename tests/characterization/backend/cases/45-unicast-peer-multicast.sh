# Per-instance unicast peer under multicast transport, with an IPv6 VIP
uci add_list ha-cluster.main.unicast_peer=172.30.0.11
uci set ha-cluster.main.unicast_src_ip=172.30.0.10
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
