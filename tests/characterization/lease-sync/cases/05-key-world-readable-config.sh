# PSK without security_mode, over a world-readable config left by an
# earlier start
uci set lease-sync.config.enabled=1
uci add_list lease-sync.config.peer=172.30.0.11
uci set lease-sync.config.psk_key=7f8e9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e
uci set lease-sync.config.plain_mode_acknowledged=0
mkdir -p /etc/lease-sync
echo "peer=172.30.0.99" > /etc/lease-sync/config
chmod 0644 /etc/lease-sync/config
