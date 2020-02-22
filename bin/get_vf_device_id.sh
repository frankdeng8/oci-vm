#!/bin/bash


eth_dev=$1
vf_id=$2


if [ -z "$eth_dev" -o -z "$vf_id" ]; then
    echo "$0 [eth dev name] [vf id]" >&2
    echo "Example: $0 eno2 62" >&2
    exit 1
fi

if [ -f /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent ]; then
   sed -n 's/PCI_SLOT_NAME=//p' /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent
fi

