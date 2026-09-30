# Source for an IPv6 peer: the route source is the IPv6 VIP, replaced by
# the other global address of the device
RPCD_METHOD=get_source_for_peer
RPCD_ARGS='{"peer_address":"fd00:192:168:50::2"}'
uci set ha-cluster.lan.address6=fd00:192:168:50::254
FAKE_ROUTE="fd00:192:168:50::2 from :: dev br-lan proto kernel src fd00:192:168:50::254 metric 256 pref medium"
FAKE_ADDRS="fd00:192:168:50::254/64 fd00:192:168:50::1/64 fe80::1/64 192.168.50.1/24"
