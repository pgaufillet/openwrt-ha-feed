# Missing dhcp force is accepted when lease sync is off
uci delete dhcp.lan.force
uci set ha-cluster.dhcp.sync_leases=0
