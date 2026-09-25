# dhcp group without an enabled option, lease-sync stopped
uci delete ha-cluster.dhcp.enabled
FAKE_RUNNING="keepalived owsync"
