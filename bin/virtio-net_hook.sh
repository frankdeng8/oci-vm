#!/bin/bash

vm_dir=$1
op=$2
nic_id=$3

vm_name=$(basename "$vm_dir")

if [ "$op" = add ]; then
    # if nic_id is 0, we don't do anything
    # as the primary nic should not be unplugged and replugged.

    # if nic_id > 0, we call imds.sh to change IMDS <vmname> <nic #>
    #  to increase vnic - $nic_id +1 in IMDS
    if [ "$nic_id" -gt 0 ]; then
        ssh oracle@ca-sysinfra604 "/usr/local/bin/imds.sh "$vm_name" "$((nic_id+1))""
    fi

elif [ "$op" = del ]; then
    # if nic_id is 0, we don't do anything
    # as the primary nic should not be unplugged and replugged.

    # if nic_id > 0, we call imds.sh <vmname> <nic #> to reduce vnic # - $nic_id in IMDS
    if [ "$nic_id" -gt 0 ]; then
        ssh oracle@ca-sysinfra604 "/usr/local/bin/imds.sh "$vm_name" "$nic_id""
    fi
fi
