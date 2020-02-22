#!/bin/bash

#bind all VFs to vfio-pci

BASE_DIR=$(readlink -f "$(dirname $0)")
for vf in $(lspci -D|grep "Virtual Function" | awk '{print $1}'); do
    $BASE_DIR/bind_vfio-pci.sh $vf
done

