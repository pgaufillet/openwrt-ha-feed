# Unicast with peers of both families: the source address sets the
# family, the IPv4 VRRP-only peer is ignored
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.address=fd00:30::11
uci set ha-cluster.peer1.source_address=fd00:30::10
uci set ha-cluster.peer2=peer
uci set ha-cluster.peer2.address=172.30.0.20
uci set ha-cluster.peer2.sync_enabled=0
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
