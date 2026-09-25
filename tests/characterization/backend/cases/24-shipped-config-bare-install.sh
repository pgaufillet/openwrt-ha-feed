# Shipped configuration, enabled, ha-cluster installed without owsync/lease-sync
cp /shipped/ha-cluster /etc/config/ha-cluster
uci set ha-cluster.config.enabled=1
rm -f /usr/bin/owsync /usr/sbin/lease-sync /etc/init.d/owsync /etc/init.d/lease-sync
