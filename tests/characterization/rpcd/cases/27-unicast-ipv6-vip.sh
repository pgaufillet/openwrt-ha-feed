# Unicast over IPv4 with an IPv6 VIP: a single instance holding the IPv6
# VIP as an excluded address
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.lan.address6=fd00:192:168:50::254
FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-unicast-evip.json"
