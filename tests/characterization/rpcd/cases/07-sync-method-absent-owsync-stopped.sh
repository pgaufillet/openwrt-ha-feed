# sync_method unset while the backend defaults to owsync
uci delete ha-cluster.config.sync_method
FAKE_RUNNING="keepalived lease-sync"
