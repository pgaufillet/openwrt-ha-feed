# Two peers running ha-cluster
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.peer2=peer
uci set ha-cluster.peer2.name=node3
uci set ha-cluster.peer2.address=172.30.0.12
