#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")

dir=

if [ -n "$1" ]; then
  dir=$1
fi

if [ ! -d "$dir" -o ! -d "$dir/write-qemu" ]; then
    echo "Usage: $0 <vm dir>"
    exit 1
fi

# use the debug monitor for shell
monitor_sock=$dir/write-qemu/monitor-debug.sock

if [ ! -S "$monitor_sock" ]; then
    echo $monitor_sock not found. >&2
    exit 2
fi
$BASE_DIR/../qmp/qmp-shell -v -p -H $monitor_sock
