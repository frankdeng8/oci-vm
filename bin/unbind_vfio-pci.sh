#!/bin/bash
#set -x

# Unbind VF from vfio-pci driver

if [ $# -eq 0 ]; then
    echo "Require PCI devices in format:  <domain>:<bus>:<slot>.<function>" 
    echo "Eg: $(basename $0) 0000:00:1b.0"
    exit 1
fi

for pcidev in $@; do
    #lspci -s $pcidev -k

    t=0
    DRIVER=
    . "/sys/bus/pci/devices/$pcidev/uevent"
    while [ "$DRIVER" = vfio-pci ]; do
    #while lspci -s $pcidev -k | grep -q "Kernel driver in use: vfio-pci"; do

        if [ $t -gt 10 ]; then
            echo "Timed out unbinding $pcidev driver from vfio-pci" >&2
            exit 1
        fi

        if [ -d "/sys/bus/pci/drivers/vfio-pci/$pcidev" ]; then
            if [ -h /sys/bus/pci/devices/"$pcidev"/driver ]; then
                #echo "Unbinding $pcidev driver from" $(basename $(readlink -f /sys/bus/pci/devices/"$pcidev"/driver))
                echo "Unbinding $pcidev driver from vfio-pci"
                echo -n "$pcidev" > /sys/bus/pci/devices/"$pcidev"/driver/unbind
                DRIVER=
                . "/sys/bus/pci/devices/$pcidev/uevent"
                if [ -z "$DRIVER" ]; then
                    break
                else
                    sleep 1
                    t=$(($t+1))
                fi
            fi
        else
            sleep 1
            t=$(($t+1))
        fi
    done
    #lspci -s $pcidev -k
    # probe driver
    echo "$pcidev" > /sys/bus/pci/drivers_probe
done
