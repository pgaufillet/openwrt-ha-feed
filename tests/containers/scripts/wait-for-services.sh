#!/bin/sh
# wait-for-services.sh - Wait for HA cluster services to be ready
#
# Usage: wait-for-services.sh [timeout_seconds]
#
# Returns 0 if all services are ready, 1 if timeout

TIMEOUT="${1:-60}"
REQUIRED_SERVICES="ubusd dnsmasq"

echo "Waiting for services (timeout: ${TIMEOUT}s)..."

count=0
while [ $count -lt $TIMEOUT ]; do
    all_ready=true

    for svc in $REQUIRED_SERVICES; do
        if ! pgrep -x "$svc" >/dev/null 2>&1; then
            all_ready=false
            break
        fi
    done

    # Check if ubus is responsive
    if $all_ready && ! ubus list >/dev/null 2>&1; then
        all_ready=false
    fi

    if $all_ready; then
        echo "All services ready."
        exit 0
    fi

    sleep 1
    count=$((count + 1))
done

echo "Timeout waiting for services!"
echo "Service status:"
for svc in $REQUIRED_SERVICES; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
        echo "  $svc: running"
    else
        echo "  $svc: NOT RUNNING"
    fi
done

exit 1
