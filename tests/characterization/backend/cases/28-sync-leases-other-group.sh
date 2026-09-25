# sync_leases set on a group other than dhcp
uci set ha-cluster.dhcp.sync_leases=0
uci set ha-cluster.firewall.enabled=1
uci set ha-cluster.firewall.sync_leases=1
