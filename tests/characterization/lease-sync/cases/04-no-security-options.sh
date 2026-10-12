# Enabled without any security option: the daemon defaults apply
uci set lease-sync.config.enabled=1
uci add_list lease-sync.config.peer=172.30.0.11
