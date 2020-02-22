#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")

dir=

if [ -n "$1" ]; then
  dir=$1
fi

if [ -z "$dir" -o ! -d "$dir" -o ! -d "$dir/write-qemu" ]; then
    echo "Usage: $0 <vm dir>"
    exit 1
fi

# use the event monitor
monitor_sock=$dir/write-qemu/monitor-event.sock

#if [ ! -S "$monitor_sock" ]; then
#    echo $monitor_sock not found. >&2
#    exit 1
#fi
while [ ! -S "$monitor_sock" ]; do
    echo $monitor_sock not found, waiting >&2
    sleep 1
done
$BASE_DIR/../qmp/qmp-monitor-events -s $monitor_sock
