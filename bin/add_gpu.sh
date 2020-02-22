#!/bin/bash

gpu_devs="0000:5e:00.0 0000:86:00.0"
pci_bridge=pci.1

./vfioback.sh $gpu_devs

index=0
for gpu in $gpu_devs; do
    echo "device_add vfio-pci,host=$gpu,bus=$pci_bridge,id=gpu${index}" | nc localhost 4444
    index=$(($index+1))
done
