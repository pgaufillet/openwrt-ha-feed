# A section named advanced already exists: the anonymous advanced section
# before it is left as is, the named one loses the persist interval
cat > /etc/config/ha-cluster <<'CONF'
config global 'config'
	option enabled '0'

config advanced
	option log_level '1'
	option lease_sync_persist_interval '30'

config advanced 'advanced'
	option log_level '3'
	option lease_sync_persist_interval '60'
CONF
