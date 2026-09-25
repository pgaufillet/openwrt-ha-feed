# Start with a service state saved by an earlier start
mkdir -p /etc/ha-cluster
printf "keepalived=0\nowsync=1\nlease-sync=0\n" > /etc/ha-cluster/service_states
