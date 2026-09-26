# owsync database left over, no enabled sync group: no config last sync
mkdir -p /etc/owsync
: > /etc/owsync/owsync.db
uci set ha-cluster.dhcp.enabled=0
