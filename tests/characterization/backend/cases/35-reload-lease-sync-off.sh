# Reload after turning lease sync off
STEP2=reload
step2() {
	uci set ha-cluster.dhcp.sync_leases=0
}
