#!/bin/bash
set -e

function hmp_send {
    echo "$*" | $BASE_DIR/../qmp/qmp-shell -v -p -H $monitor_sock
}

BASE_DIR=$(dirname "$(readlink -f $0)")

dir=

if [ -n "$1" ]; then
  dir=$1
fi

if [ ! -d "$dir" -o ! -d "$dir/write-qemu" ]; then
    echo "Usage: $0 <vm dir> <cmd>"
    echo "    or echo <cmd> | $0 <vm dir>"
    exit 1
fi

monitor_sock=$dir/write-qemu/monitor.sock
if [ ! -S "$monitor_sock" ]; then
    echo $monitor_sock not found. >&2
    exit 1
fi

shift
cmd="$*"

if [ -n "$cmd" ]; then
    echo "HMP CMD: $cmd"
    hmp_send "$cmd"
else
    while read cmd; do
        if ! echo "$cmd" | grep -q "^#"; then
            echo "HMP CMD: $cmd"
            hmp_send "$cmd"
        fi
    done < "${2:-/dev/stdin}"
fi
