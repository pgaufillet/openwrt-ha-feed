# owsync and lease-sync not installed, and nothing for them to sync
rm -f /usr/bin/owsync /usr/sbin/lease-sync /etc/init.d/owsync /etc/init.d/lease-sync
uci set ha-cluster.config.sync_method=none
uci set ha-cluster.dhcp.sync_leases=0
FAKE_RUNNING="keepalived"
