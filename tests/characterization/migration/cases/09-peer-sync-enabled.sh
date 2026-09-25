# sync_enabled false spellings become vrrp_only 1, true ones are dropped,
# named and anonymous peers alike
cat > /etc/config/ha-cluster <<'CONF'
config config 'config'
	option enabled '1'

config peer 'peer1'
	option address '172.30.0.11'
	option sync_enabled '0'

config peer
	option address '172.30.0.12'
	option sync_enabled 'false'

config peer
	option address '172.30.0.13'
	option sync_enabled 'off'

config peer 'peer4'
	option address '172.30.0.14'
	option sync_enabled '1'

config peer 'peer5'
	option address '172.30.0.15'
	option sync_enabled 'yes'
	option vrrp_only '1'

config peer 'peer6'
	option address '172.30.0.16'
CONF
