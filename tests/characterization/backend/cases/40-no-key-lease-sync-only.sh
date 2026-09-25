# No encryption key, owsync not installed: lease-sync alone in plain mode
uci delete ha-cluster.config.encryption_key
rm -f /usr/bin/owsync /etc/init.d/owsync
