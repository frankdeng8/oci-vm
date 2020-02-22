#!/bin/bash
set -e -x

BASE_DIR=$(dirname "$(readlink -f $0)")

dir=$(pwd)

if [ -n "$1" ]; then
  dir=$1
fi

if [ ! -d $dir ]; then
    echo $dir not found. >&2
    exit 1
fi

monitor_sock=$dir/write-qemu/monitor.sock
function qmp_send {
    echo "$*" | $BASE_DIR/../qmp/qmp-shell -H $monitor_sock
}

if [ ! -S $monitor_sock ]; then
    echo $monitor_sock not found. >&2
    exit 1
fi

if qmp_send "info status" | grep -q "running"; then
    qmp_send "system_powerdown"
    sleep 10
    while qmp_send "info status" | grep -q "running"; do
        sleep 3
    done
fi
qmp_send "quit"
