#!/bin/bash
# set -x

# Bind VF to vfio-pci

if [ $# -eq 0 ]; then
    echo "Require PCI devices in format:  <domain>:<bus>:<slot>.<function>" 
    echo "Eg: $(basename $0) 0000:00:1b.0"
    exit 1
fi

for pcidev in $@; do

    # check if the pci device exists
    if ! lspci -s $pcidev >/dev/null 2>&1; then
        continue
    fi

    #if ! lspci -s $pcidev -k | grep -q "Kernel driver in use: vfio-pci"; then

    DRIVER=
    . "/sys/bus/pci/devices/$pcidev/uevent"
    # if the VF driver is not vfio-pci, unbind from existing driver then bind to vfio-pci
    if [ "$DRIVER" != vfio-pci ]; then
        while [ -n "$DRIVER" ]; do
            echo "Unbinding $pcidev driver from $DRIVER"
            echo -n "$pcidev" > "/sys/bus/pci/devices/$pcidev/driver/unbind"
            # validate it is unbound
                DRIVER=
                . "/sys/bus/pci/devices/$pcidev/uevent"
                if [ -z "$DRIVER" ]; then
                    break
                else
                    sleep 1
                fi
        done
        # bind to vfio
        if [ ! -f /sys/bus/pci/drivers/vfio-pci/new_id ]; then
            echo "Loading vfio-pci"
            modprobe vfio-pci
        fi
        echo "Binding $pcidev driver to vfio-pci"
            #pcidev_bdf_num=$(lspci -s $pcidev -n | awk '{print $3}' | tr ':' ' ')
        vendor=$(cat /sys/bus/pci/devices/$pcidev/vendor)
        device=$(cat /sys/bus/pci/devices/$pcidev/device)
        echo "$vendor $device" > /sys/bus/pci/drivers/vfio-pci/new_id

        # validate vfio-pci driver
        DRIVER=
        . "/sys/bus/pci/devices/$pcidev/uevent"
        while [ -z "$DRIVER" ]; do
            sleep 1
            DRIVER=
            . "/sys/bus/pci/devices/$pcidev/uevent"
        done
        if [ "$DRIVER" != vfio-pci ]; then
            echo "Couldn't bind $pcidev driver to vfio-pci." >&2
            exit 1
        fi
    else
        echo "$pcidev driver is already bound to vfio-pci"
    fi

    # # if the VF driver is not vfio-pci
    # if [ ! -d "/sys/bus/pci/drivers/vfio-pci/$pcidev" ]; then
    #     # unbind it from current driver - ethernet driver
    #     if [ -h /sys/bus/pci/devices/"$pcidev"/driver ]; then
    #         echo "Unbinding $pcidev from" $(basename $(readlink -f /sys/bus/pci/devices/"$pcidev"/driver))
    #         echo -n "$pcidev" > /sys/bus/pci/devices/"$pcidev"/driver/unbind
    #     fi
    #     if [ ! -f /sys/bus/pci/drivers/vfio-pci/new_id ]; then
    #         echo "Loading vfio-pci"
    #         modprobe vfio-pci
    #     fi
    #     echo "Binding $pcidev to vfio-pci"
    #         #pcidev_bdf_num=$(lspci -s $pcidev -n | awk '{print $3}' | tr ':' ' ')
    #     vendor=$(cat /sys/bus/pci/devices/$pcidev/vendor)
    #     device=$(cat /sys/bus/pci/devices/$pcidev/device)
    #     echo "$vendor $device" > /sys/bus/pci/drivers/vfio-pci/new_id
    # fi
    # lspci -s $pcidev -k
    #if [ $op = attach ]; then
    #   echo "device_add vfio-pci,host=$pcidev,bus=$pci_bridge,id=vf${vf_bus}${vf_device}${vf_function}" | nc localhost 4444
    #elif [ $op = detach ]; then
    #   echo "device_del vf${vf_bus}${vf_device}${vf_function}" | nc localhost 4444
    #fi
done
