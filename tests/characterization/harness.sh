#!/bin/sh
# Runs one characterization case in a throwaway node container and prints
# its observable result.
# Usage: harness.sh backend|rpcd|acl|migration <case file>
#
# A case file is sourced with errexit set. It may change UCI, remove or
# create files, set the FAKE_* variables read by the stubs, and set
# STEP2=reload|stop (with an optional step2 function applying changes
# first) to observe a second step after the first start. rpcd cases may
# set RPCD_METHOD to call another method than status, and RPCD_ARGS to
# the JSON arguments rpcd passes on stdin.
#
# Cases describe the configuration before the package upgrade: the
# uci-defaults migration runs on it before the first start. step2
# changes are made after the upgrade and use the current option names.
#
# Migration cases write /etc/config/ha-cluster verbatim; only the
# uci-defaults migration runs, twice.
#
# ACL cases define a checks function calling access and file_call, run
# against a real ubusd/rpcd with a restricted login.

exec 2>&1

mode="$1"
case_file="$2"
CHAR=/char

export PATH="$CHAR/stubs:$PATH"
export CHAR_LOG=/tmp/char.log
: > "$CHAR_LOG"

cp "$CHAR/base-ha-cluster" /etc/config/ha-cluster
cp "$CHAR/base-dhcp" /etc/config/dhcp
rm -rf /tmp/ha-cluster /etc/ha-cluster /tmp/dnsmasq*.d
rm -f /etc/owsync/owsync.db /tmp/dhcp.leases

# Standalone services enabled, whatever the image build left
for service in keepalived owsync lease-sync; do
	[ -x "/etc/init.d/$service" ] && "/etc/init.d/$service" enable
done

# rpcd defaults: every daemon running, peer reachable, VRRP MASTER, no
# route and no address for get_source_for_peer
export FAKE_RUNNING="keepalived owsync lease-sync"
export FAKE_ONLINE="172.30.0.11"
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-master.json"
export FAKE_ROUTE=""
export FAKE_ADDRS=""

STEP2=""
RPCD_METHOD=status
RPCD_ARGS="{ }"
set -e
. "$case_file"
uci commit
set +e

args() {
	printf ' [%s]' "$@"
	echo
}

show_file() {
	echo "== $1"
	if [ -f "$1" ]; then
		cat "$1"
	else
		echo "(absent)"
	fi
}

show_dir() {
	echo "== ls $1"
	if [ -d "$1" ]; then
		ls -A "$1"
	else
		echo "(absent)"
	fi
}

# The init script without rc.common: procd calls are printed, and
# start/stop run the service functions directly.
load_init() {
	. /etc/init.d/ha-cluster

	procd_open_instance() { printf 'instance'; args "$@"; }
	procd_set_param() { printf '\tset'; args "$@"; }
	procd_append_param() { printf '\tappend'; args "$@"; }
	procd_close_instance() { echo "end"; }
	procd_add_reload_trigger() { printf 'reload_trigger'; args "$@"; }
	procd_running() { return 0; }
	procd_send_signal() { printf 'signal'; args "$@"; }
	start() { start_service; }
	stop() { stop_service; }
}

observe() {
	echo "== log"
	cat "$CHAR_LOG"
	: > "$CHAR_LOG"
	show_dir "$HA_CLUSTER_RUN_DIR"
	show_file "$KEEPALIVED_CONF"
	show_file "$OWSYNC_CONF"
	show_file "$LEASE_SYNC_CONF"
	local confdir
	confdir="$(ha_get_dnsmasq_confdir)"
	show_dir "$confdir"
	show_file "$confdir/$HA_DNSMASQ_OVERLAY_NAME"
	show_dir /etc/ha-cluster
	show_file /etc/ha-cluster/service_states
	echo "== rc.d"
	ls /etc/rc.d | grep -E 'keepalived|owsync|lease-sync|ha-cluster' || echo "(none)"
}

case "$mode" in
	backend)
		echo "== uci"
		uci export ha-cluster
		uci export dhcp

		sh /char-migrate
		echo "== uci after migration"
		uci export ha-cluster

		load_init

		echo "== start_service"
		start_service
		echo "rc=$?"
		echo "== service_triggers"
		service_triggers
		observe

		if [ -n "$STEP2" ]; then
			set -e
			command -v step2 >/dev/null && step2
			uci commit
			set +e
			echo "== $STEP2"
			case "$STEP2" in
				reload) reload_service ;;
				stop) stop_service ;;
			esac
			echo "rc=$?"
			observe
		fi
		;;
	rpcd)
		sh /char-migrate
		# rpcd may read what the backend generated
		( load_init; start_service ) > /dev/null 2>&1
		# Fixed mtimes for the "last sync" timestamps
		for f in /etc/owsync/owsync.db /tmp/dhcp.leases; do
			[ -f "$f" ] && touch -d "2026-01-01 00:00:00" "$f"
		done
		# Raw JSON on the last line: a jshn round trip would rename keys
		out="$(printf '%s' "$RPCD_ARGS" | /usr/libexec/rpcd/ha-cluster call "$RPCD_METHOD")"
		echo "== $RPCD_METHOD rc=$?"
		echo "$out"
		;;
	acl)
		# A login holding only luci-base and the app's ACL groups, as
		# granted to a non-root LuCI user
		cat >> /etc/config/rpcd <<-EOF

			config login
				option username 'char'
				option password '$(/usr/sbin/uhttpd -m char)'
				list read 'luci-base*'
				list read 'luci-app-ha-cluster'
				list write 'luci-base*'
				list write 'luci-app-ha-cluster'
		EOF
		/sbin/ubusd &
		while [ ! -S /var/run/ubus/ubus.sock ]; do sleep 1; done
		/sbin/rpcd &
		/bin/ubus -t 10 wait_for session file
		sid="$(/bin/ubus call session login '{"username":"char","password":"char"}' |
			sed -n 's/.*"ubus_rpc_session": "\([0-9a-f]*\)".*/\1/p')"
		if [ -z "$sid" ]; then
			echo "login failed"
			exit 1
		fi

		# Usage: access <scope> <object> <function>
		# Asks the session: uhttpd checks the ubus scope before any call
		access() {
			echo "access $1 $2 $3: $(/bin/ubus call session access \
				"{\"ubus_rpc_session\":\"$sid\",\"scope\":\"$1\",\"object\":\"$2\",\"function\":\"$3\"}" |
				sed -n 's/.*"access": \([a-z]*\).*/\1/p')"
		}

		# Usage: file_call <method> <path> [<extra JSON members>]
		# The file scope is enforced by rpcd on the call itself
		file_call() {
			local err

			if err="$(/bin/ubus call file "$1" \
				"{\"path\":\"$2\",\"ubus_rpc_session\":\"$sid\"${3:+,$3}}" 2>&1 >/dev/null)"; then
				echo "file $1 $2: ok"
			else
				echo "file $1 $2: ${err##*(}" | sed 's/)$//'
			fi
		}

		checks
		;;
	migration)
		config=/etc/config/ha-cluster
		show_file "$config"
		sh /char-migrate
		echo "== migration rc=$?"
		show_file "$config" | tee /tmp/char-first
		sh /char-migrate
		echo "== second run rc=$?"
		show_file "$config" > /tmp/char-second
		if cmp -s /tmp/char-first /tmp/char-second; then
			echo "(unchanged)"
		else
			cat /tmp/char-second
		fi
		;;
esac

exit 0
