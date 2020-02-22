#!/bin/bash

# example:  create_vfs.sh -d 0000:30:00.1 -m ol7 -o attach

gen_mac () {
    local prefix=$1
    local id=$2
    echo "${prefix}$(printf "%04x" $id | sed 's/\(..\)/\1:/g; s/.$//')"

}

# get pci address from a eth dev name

get_eth_pci () {
    ethtool -i $1 2>/dev/null | grep bus-info | awk '{print $2}'
}

# get eth dev name from pci address
get_eth_dev () {
    local eth_devs=$(ip link show |egrep ^[0-9]*: | awk -F: '{print $2}')
    local eth_dev
    for eth_dev in $eth_devs; do
        if [ "$eth_dev" = "lo" ]; then
            continue
        fi
        #local bus=$(ethtool -i $eth_dev | grep bus-info | awk '{print $2}' | sed 's/^[0-9]\{4\}://')
        local bus=$(ethtool -i $eth_dev | grep bus-info | awk '{print $2}')
        if [ "$bus" = "$1" ]; then
            echo $eth_dev
            break
        fi
    done
}

sysfs_vf () {
    local op=$1
    local vm=$2
    local vf_bdf=$3
    local mac=$4
    local pci_bridge=$5
    local vf_domain=$(echo $vf_bdf | awk -F: '{print $1}')
    local vf_bus=$(echo $vf_bdf | awk -F: '{print $2}')
    local vf_device=$(echo $vf_bdf | awk -F: '{print $3}' | awk -F. '{print $1}')
    local vf_function=$(echo $vf_bdf | awk -F: '{print $3}' | awk -F. '{print $2}')

    if ! lspci -s $vf_bdf -k | grep -q "Kernel driver in use: vfio-pci"; then
        echo -n "$vf_bdf" > "/sys/bus/pci/devices/$vf_bdf/driver/unbind"
        local vf_bdf_num=$(lspci -s $vf_bdf -n | awk '{print $3}' | tr ':' ' ')
        if [ ! -f /sys/bus/pci/drivers/vfio-pci/new_id ]; then
            modprobe vfio-pci
        fi
        echo $vf_bdf_num >  /sys/bus/pci/drivers/vfio-pci/new_id
        #lspci -s $vf_bdf -k
    fi
    if [ $op = attach ]; then
       echo "device_add vfio-pci,host=$vf_bdf,bus=$pci_bridge,id=vf${vf_bus}${vf_device}${vf_function}" | nc localhost 4444
    elif [ $op = detach ]; then
       echo "device_del vf${vf_bus}${vf_device}${vf_function}" | nc localhost 4444
    fi

}

# $1 attach/detach
# $2 vm name
# $3 pci address format: <domain>:<bus>:<slot>.function, get this info by 'lspci -D'
# $4 mac address

# pci name in libvirt
#pci_name="pci_$(echo $vf_bdf | tr ':' '_' | tr '.' '_')"
#echo $pci_name
#virsh nodedev-dumpxml $pci_name

libvirt_vf() {
    local op=$1
    local vm=$2
    local vf_bdf=$3
    local mac=$4
    local vf_domain=$(echo $vf_bdf | awk -F: '{print $1}')
    local vf_bus=$(echo $vf_bdf | awk -F: '{print $2}')
    local vf_device=$(echo $vf_bdf | awk -F: '{print $3}' | awk -F. '{print $1}')
    local vf_function=$(echo $vf_bdf | awk -F: '{print $3}' | awk -F. '{print $2}')
    cat > /tmp/vf.xml <<-VFXML
<interface type='hostdev' managed='yes'>
  <mac address='$mac'/>
  <source>
    <address type='pci' domain='0x$vf_domain' bus='0x$vf_bus' slot='0x$vf_device' function='0x$vf_function'/>
  </source>
</interface>
VFXML
    #cat /tmp/vf.xml
    if [ "$op" = attach ]; then
        if virsh list --name | egrep -q "^$vm$"; then
            virsh attach-device $vm  /tmp/vf.xml --config --live
        else
            virsh attach-device $vm  /tmp/vf.xml --config
        fi
    elif [ "$op" = detach ]; then
        if virsh list --name | egrep -q "^$vm$"; then
            virsh detach-device $vm  /tmp/vf.xml --config --live
        else
            virsh detach-device $vm  /tmp/vf.xml --config
        fi
    fi
}

#if [ -z "$1" ]; then
#    echo "$0 <pci device uniq description in lspci>" >&2
#    exit 1
#fi


#PF pci info
#bdfs=$(lspci | grep "$1" | grep -v "Virtual Function" | awk '{print $1}')


usage () {
    echo "Usage:"
    echo "1. create VFs with PF PCI addresss"
    echo "$0 -p '<device1_pci_address> <device2_pci_address> ...' -m <vm name> -n <num of vf> -o [attach|detach]"
    echo "Example: $0 -p '0000:3b:00.0 0000:3b:00.1'"
    echo "2. create VFs with PF device name"
    echo "$0 -d '<device1 name> <device2 name> ...'"
    echo "Example: $0 -d 'eno2 eno3'"
    echo "Obtain device pci address by command 'lspci -D'"
}

while getopts "d:p:m:n:o:h" OPTION; do
    case "$OPTION" in
      d)
        devices=$OPTARG
        ;;
      p)
        bdfs=$OPTARG
        ;;
      m)
        vm=$OPTARG
        ;;
      n)
        vm_vf_num=$OPTARG
        ;;
      o)
        op=$OPTARG
        ;;
      h)
        usage
        exit 0
        ;;
      *)
        usage
        exit 0
        ;;
    esac
done

if [ -z "$bdfs" -a -z "$devices" ]; then
    echo "device not found" >&2
    usage
    exit 2
fi


if [ -n "$devices" ]; then
    for d in $devices; do
        pci=$(get_eth_pci $d)
        if [ -z "$pci" ]; then
            echo "$d dosn't exit."
            continue
        fi
        bdfs="$bdfs $pci"
    done
fi

# PCI address format  Domain:Bus:Device.Function
# example: 0000:30:00.01

index=0

for bdf in $bdfs; do
    #Initial VFs: 64, Total VFs: 64, Number of VFs: 0,
    echo "Device BDF: $bdf"
    s=$(lspci -s $bdf -vv | grep "Initial VFs")
    if [ -z "$s" ]; then
        echo "the device does not support VFs" >&2
        continue
    fi
    #total_vfs=$(echo $s | sed -e 's/.*Total VFs: \([0-9]*\),.*/\1/')
    #echo "Total VFs supported: $total_vfs"
    eth_dev=$(get_eth_dev $bdf)
    echo "Device name: $eth_dev"
    if [ -z "$eth_dev" ]; then
        echo "device name not found" >&2
        continue
    fi
    echo "Found device name: $eth_dev"
    total_vfs=$(cat "/sys/class/net/$eth_dev/device/sriov_totalvfs")
    echo "Total VFs supported: $total_vfs"
    if [ -f "/sys/class/net/$eth_dev/device/sriov_numvfs" ]; then
        orig_num_vfs=$(cat "/sys/class/net/$eth_dev/device/sriov_numvfs")
        if [ "$orig_num_vfs" -eq "$total_vfs" ]; then
            echo "VFs already created."
        else
            # set it to 0
            if [ "$orig_num_vfs" -gt 0 -a "$orig_num_vfs" -lt "$total_vfs" ]; then
                echo "Removing $orig_num_vfs VFs."
                echo 0 > /sys/class/net/$eth_dev/device/sriov_numvfs
                sleep 1
            fi
            echo "Creating VFs."
            echo $total_vfs > /sys/class/net/$eth_dev/device/sriov_numvfs

            # verify and wait until the vf driver bond to ixgbevf or bnxt_en
            for vf_id in 0 $(($total_vfs-1)); do
                while [ ! -f /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent ]; do
                    sleep 1
                done
                . /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent 
                driver=$DRIVER
                while [ -z "$driver" ]; do
                    sleep 1
                    . /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent 
                    driver=$DRIVER
                done
            done
            # wait 1 more second.
            sleep 1
        fi
    fi
    # verify vf num
    s=$(lspci -s $bdf -vv | grep "Initial VFs")
    num_vfs=$(echo $s | sed -e 's/.*Number of VFs: \([0-9]*\),.*/\1/')
    echo "Number of VFs: $num_vfs"
    if [ "$(ip link show $eth_dev | grep vf | wc -l)" != $total_vfs ]; then
        echo "VFs not created." >&2
        continue
    fi
    if [ -n "$vm" ]; then
        echo "Assigning VFs to VM $vm"
        # get VFs
        #for vf_id in $(seq 0 $num_vfs); do
        for vf_id in $(seq 0 $(($vm_vf_num-1))); do
            if [ -f /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent ]; then
                vf_bdf=$(grep PCI_SLOT_NAME /sys/class/net/$eth_dev/device/virtfn$vf_id/uevent | sed 's/.*=//')
                mac=$(gen_mac "50:50:50:50:" $index)
                index=$(($index+1))
                #libvirt_vf $op $vm $vf_bdf $mac
                if [ $index -lt 20 ];then
                    sysfs_vf $op $vm $vf_bdf $mac "pci.1"
                else
                    sysfs_vf $op $vm $vf_bdf $mac "pci.2"
                fi

            fi
        done
    #virsh dumpxml $vm
    fi
done

