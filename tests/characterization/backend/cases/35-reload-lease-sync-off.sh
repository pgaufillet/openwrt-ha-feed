# Reload after turning lease sync off
STEP2=reload
step2() {
	uci set ha-cluster.config.lease_sync=0
}
