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

if ! which socat >/dev/null 2>&1; then
    echo "yum install socat first" >&2
    exit 1
fi

serial_sock=$dir/write-qemu/serial.sock
#if [ ! -S "$serial_sock" ]; then
#    echo $serial_sock not found. >&2
#    exit 1
#fi
while [ ! -S "$serial_sock" ]; do
    echo "$serial_sock not found, waiting" >&2
    sleep 1
done
echo
echo "Starting Console... (ctrl+q to quit)"
echo
socat stdin,raw,echo=0,escape=0x11 "unix-connect:$serial_sock"
