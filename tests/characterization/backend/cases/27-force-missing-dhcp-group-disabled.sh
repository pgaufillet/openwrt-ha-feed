# Missing dhcp force with the dhcp group disabled and sync_leases set
uci delete dhcp.lan.force
uci set ha-cluster.dhcp.enabled=0
