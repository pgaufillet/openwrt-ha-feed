# Validation: VRID shared by two instances
uci set ha-cluster.guest=vrrp_instance
uci set ha-cluster.guest.vrid=51
uci set ha-cluster.guest.interface=guest
