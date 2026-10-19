# dnsmasq-ha

dnsmasq with ubus lease management patches

## Overview

Replaces the stock dnsmasq with a version adding UBUS methods (add_lease,
delete_lease, get_leases) required for HA DHCP lease synchronization.
Cannot be installed alongside dnsmasq or dnsmasq-full.
