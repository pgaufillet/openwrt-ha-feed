# dnsmasq authoritative, lease sync off, dhcp listed but sync_dir does
# not contain /etc/config/dhcp: warning, sync_dir is not taken into
# account; still one once sync_dir is /etc/config/ again
uci set ha-cluster.dhcp.sync_leases=0
uci set ha-cluster.config.sync_dir=/srv/sync
uci set dhcp.@dnsmasq[0].authoritative=1
STEP2=reload
step2() {
	uci set ha-cluster.config.sync_dir=/etc/config/
}
