# dhcp group disabled, sync_leases still set, lease-sync stopped
uci set ha-cluster.dhcp.enabled=0
FAKE_RUNNING="keepalived owsync"
