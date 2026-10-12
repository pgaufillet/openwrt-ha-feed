# Plain mode, acknowledged
uci set lease-sync.config.enabled=1
uci add_list lease-sync.config.peer=172.30.0.11
uci set lease-sync.config.security_mode=plain
uci set lease-sync.config.plain_mode_acknowledged=1
