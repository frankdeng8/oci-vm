#!/bin/bash
# set -x

# Unbind VF from vfio-pci driver

if [ $# -eq 0 ]; then
    echo "Usage: $0 <pf dev>"
    echo "Eg: $(basename $0) eno3d1"
    exit 1
fi

pf_dev=$1

BASE_DIR=$(dirname "$(readlink -f $0)")

if [ -f /sys/class/net/$pf_dev/device/sriov_numvfs ]; then
    vf_num=$(cat /sys/class/net/$pf_dev/device/sriov_numvfs)
    vf_num=30
    vf_id=0
    echo "sysfs:"
    while [ $vf_id -lt $vf_num ]; do
        vf_pci_addr=$($BASE_DIR/get_vf.sh $pf_dev $vf_id)
        #echo $vf_pci_addr
        DRIVER=
        if [ -f "/sys/bus/pci/devices/$vf_pci_addr/uevent" ]; then
            . "/sys/bus/pci/devices/$vf_pci_addr/uevent"
        fi
        #if [ -n "$DRIVER" ]; then
        #fi
        # verify
        driver=
        if [ -d "/sys/bus/pci/drivers/vfio-pci/$vf_pci_addr" ]; then
            driver=vfio-pci
        fi
        mac=$(ip link show $pf_dev | grep "vf $vf_id " | awk '{print $4}' | sed 's/,//')
        vlan=
        if ip link show $pf_dev | grep "vf $vf_id " | grep -q vlan; then
            vlan=$(ip link show $pf_dev | grep "vf $vf_id " | awk '{print $6}' | sed 's/,//')
        fi

        if [ "$driver" = vfio-pci -o "$DRIVER" = vfio-pci ] && [ "$DRIVER" != "$driver" ]; then
            echo "unmatched driver for $pf_dev vf $vf_id $vf_pci_addr"
            echo "$pf_dev vf $vf_id $vf_pci_addr driver $DRIVER/$driver mac $mac vlan $vlan"
        else
            echo "$pf_dev vf $vf_id $vf_pci_addr driver $DRIVER mac $mac vlan $vlan"
        fi
        vf_id=$(($vf_id+1))

    done
fi

if [ -f ~/.qemu/vm.db ]; then
    echo vf in vm.db:
    sqlite3 ~/.qemu/vm.db 'select * from vf;'
fi
