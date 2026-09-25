# VRRP-only peer unreachable, sync peer online
uci set ha-cluster.peer2=peer
uci set ha-cluster.peer2.address=172.30.0.20
uci set ha-cluster.peer2.sync_enabled=0
