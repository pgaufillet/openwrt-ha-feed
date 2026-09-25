# Several groups, file patterns and an extra exclude
uci set ha-cluster.firewall.enabled=1
uci add_list ha-cluster.firewall.config_files=firewall.user
uci set ha-cluster.misc=service
uci add_list ha-cluster.misc.config_files=uhttpd
uci add_list ha-cluster.misc.config_files=dropbear
uci add_list ha-cluster.@exclude[0].file=wireless
