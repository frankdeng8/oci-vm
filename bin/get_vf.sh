#!/bin/bash

eth_dev=$1
vf_id=$2

if [ -z "$eth_dev" ]; then
    echo "$0 [eth dev name] [optional vf id]"
    echo "Example: $0 eno2 [62]" >&2
    exit 1
fi

if [ -f /sys/class/net/$eth_dev/device/sriov_numvfs ]; then

    if [ -n "$vf_id" ]; then
        if [ -f /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent ]; then
           sed -n 's/PCI_SLOT_NAME=//p' /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent
        fi
    else
        num_vfs=$(cat /sys/class/net/$eth_dev/device/sriov_numvfs)
        for vf_id in $(seq 0 $num_vfs); do
            if [ -f /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent ]; then
               sed -n 's/PCI_SLOT_NAME=//p' /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent
            fi
        done
    fi
fi
