# Source for an IPv4 peer: the route source is the VIP, replaced by the
# other address of the device
RPCD_METHOD=get_source_for_peer
RPCD_ARGS='{"peer_address":"192.168.50.2"}'
FAKE_ROUTE="192.168.50.2 dev br-lan src 192.168.50.254 uid 0"
FAKE_ADDRS="192.168.50.254/24 192.168.50.1/24"
