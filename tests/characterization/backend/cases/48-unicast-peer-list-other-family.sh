# Per-instance unicast peer list of another family than the source
# address: an error, the source address is ignored
uci add_list ha-cluster.main.unicast_peer=fd00:30::11
uci add_list ha-cluster.main.unicast_peer=fd00:30::12
uci set ha-cluster.main.unicast_src_ip=172.30.0.10
