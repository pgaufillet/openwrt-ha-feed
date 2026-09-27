# Unicast source address of another family than every peer: an error,
# the source address is ignored and the peers set the family
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.main.unicast_src_ip=172.30.0.10
uci set ha-cluster.peer1.address=fd00:30::11
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
