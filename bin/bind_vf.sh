#!/bin/bash
# set -x
# Bind VF to vfio-pci

if [ $# -ne 2 ]; then
    echo "Eg: $(basename $0) <PF dev name> <vf id>"
    exit 1
fi

iface=$1
vf_id=$2

vf=virtfn$vf_id

if [ ! -d "/sys/class/net/$iface" ]; then
    echo "$iface doesn't exist" >&2
    exit 1
fi

if [ ! -d "/sys/class/net/$iface/device/$vf" ]; then
    echo "$vf on $iface doesn't exist." >&2
    exit 2
fi

driver=""
if [ -d /sys/class/net/${iface}/device/${vf}/driver ]; then
    driver="$(basename "$(readlink /sys/class/net/${iface}/device/${vf}/driver)")"
fi

if [ "$driver" != vfio-pci ]; then
    if [ ! -f /sys/bus/pci/drivers/vfio-pci/new_id ]; then
        echo "Loading vfio-pci module."
        modprobe vfio-pci
    fi
    #echo "Assigning ${vf} on ${iface} to vfio-pci driver..."
    pci="$(basename "$(readlink /sys/class/net/${iface}/device/${vf})")"
    echo "Binding vf $vf_id on $iface($pci) driver to vfio-pci"
    echo vfio-pci > /sys/class/net/${iface}/device/${vf}/driver_override
    if [ -n "$driver" ]; then
        # only unbind when it's already bind to a driver
        echo $pci > /sys/class/net/${iface}/device/${vf}/driver/unbind
    fi
    echo $pci > /sys/bus/pci/drivers_probe
    echo > /sys/class/net/${iface}/device/${vf}/driver_override

        # validate vfio-pci driver
        DRIVER=
        . "/sys/bus/pci/devices/$pci/uevent"
        while [ -z "$DRIVER" ]; do
            sleep 1
            DRIVER=
            . "/sys/bus/pci/devices/$pci/uevent"
        done
        if [ "$DRIVER" != vfio-pci ]; then
            echo "Couldn't bind vf $vf_id on $iface($pci) driver to vfio-pci." >&2
            exit 3
        fi
else
    echo "vf $vf_id on $iface driver is already bound to vfio-pci"
fi
