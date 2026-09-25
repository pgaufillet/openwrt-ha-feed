# Unicast VRRP derived from the peer sections
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.peer2=peer
uci set ha-cluster.peer2.address=172.30.0.20
uci set ha-cluster.peer2.sync_enabled=0
