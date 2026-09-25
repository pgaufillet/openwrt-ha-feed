# Lease sync off: lease-sync not required
uci set ha-cluster.dhcp.sync_leases=0
FAKE_RUNNING="keepalived owsync"
