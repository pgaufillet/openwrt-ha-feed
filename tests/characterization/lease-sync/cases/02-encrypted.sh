# Enabled with a PSK and two peers, one with a source address
uci set lease-sync.config.enabled=1
uci set lease-sync.config.node_id=node-a
uci add_list lease-sync.config.peer=172.30.0.11
uci add_list lease-sync.config.peer=172.30.0.12,172.30.0.10
uci set lease-sync.config.security_mode=encrypted
uci set lease-sync.config.psk_key=7f8e9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e
