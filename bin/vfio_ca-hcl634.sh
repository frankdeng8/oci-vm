#!/bin/bash
set -e


#bnxt_devs="0000:3b:00.0 0000:3b:00.1"
# create bnxt VFs
#./create_vf.sh -p "$bnxt_devs"

BASE_DIR=$(dirname "$(readlink -f $0)")

echo $SCRIPT_DIR

eth_devs="eno2 eno3d1"
$BASE_DIR/create_vf.sh -d "$eth_devs"

# bind all VFs to vfio

for dev in $eth_devs; do
    vfs=$($BASE_DIR/get_vf.sh $dev)
    $BASE_DIR/bind_vfio-pci.sh $vfs
done

# bind gpus to vfio
gpu_devs="0000:5e:00.0 0000:86:00.0"
$BASE_DIR/bind_vfio-pci.sh $gpu_devs

