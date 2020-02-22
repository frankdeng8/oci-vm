#!/bin/bash
set -e
#set -x

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -P <vm working dir> -o [add|del]"
    echo "Options:"
    echo "  -P [VM working directory]"
    echo "  -o [add|del], hot add or del virtio-net"
    echo "      add: QMP: device_add"
    echo "      del: QMP: device_del"
    echo "  -n nic id, 0 or 1, default 0"
    echo "  -s append 'standby=on'"
    echo "  -k run a hook script along with the add/del operations"
    echo "Example: $0 -o add -n 1 -P ~/myvms/ol1"
}

hostname=
pf_dev=
nic_id=0
dir=
op=
standby=0
hook=

while getopts "o:P:n:k:sh" OPTION; do
    case "$OPTION" in
      o)
        op=$OPTARG
        ;;
      n)
        nic_id=$OPTARG
        ;;
      s)
        standby=1
        ;;
      P)
        dir=$OPTARG
        ;;
      k)
        hook=$OPTARG
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

# vm working dir
if [ -z "$dir" -o ! -d "$dir" -o ! -d "$dir/write-qemu" ]; then
    echo "VM working dir not found." >&2
    usage
    exit 1
fi
# operation
if [ -z "$op" ]; then
    echo "operation not found" >&2
    usage
    exit 1
fi

if [ -n "$hook" ] && [ ! -x "$hook" ]; then
    echo "$hook not found or not executable."
    exit 1
fi

# use abs path for vm work dir
dir=$(readlink -f "$dir")

#hostname and pf_dev
if [ -f "$dir/hostname" ]; then
    hostname=$(cat $dir/hostname)
else
    echo "$dir/hostname not found." >&2
    usage
    exit 1
fi

pf_dev=$(cat $dir/pf_dev)
if ! ip link show $pf_dev >/dev/null; then
    echo "$pf_dev not found" >&2
    exit 1
fi

# MAC
mac=$(get_mac $hostname $nic_id)

ipxe_boot=$(cat $dir/ipxe_boot)
efirom_file=$(get_efirom_file $dir $ipxe_boot 'virtio')

#if [ "$op" = set -o "$op" = up ]; then
    #set_vf "$hostname" "$pf_dev" "$max_tx_rate" "$nic_id"
#elif [ "$op" = unset -o "$op" = down ]; then
    #unset_vf $vf_pci_addr
#elif [ "$op" = add ]; then
if [ "$op" = add ]; then
    # dev_add vf
    echo "Attaching virtio-net-pci $nic_id on $pf_dev to VM $hostname"
    #efirom_file=$(get_efirom_file $dir $ipxe_boot $vf_pci_addr)
    #cmd="device_add driver=virtio-net-pci,netdev=hostnet$nic_id,id=net$nic_id,mac=$mac,romfile=$romfile,bootindex=$(($nic_id+1))"
    cmd="device_add driver=virtio-net-pci netdev=hostnet$nic_id id=net$nic_id mac=$mac bootindex=$(($nic_id+1))"

    if [ $nic_id -eq 0 ]; then
        cmd="$cmd romfile=$efirom_file"
    fi
    if [ $standby -eq 1 ]; then
        cmd="$cmd standby=on"
    fi
    #$BASE_DIR/hmp.sh "$dir" "$cmd"
    $BASE_DIR/qmp.sh "$dir" "$cmd"
    if [ -n "$hook" ]; then
        echo "Executing hook script '$hook $dir $op $nic_id'"
        $hook "$dir" "$op" "$nic_id"
    fi

elif [ "$op" = del ]; then
    echo "Detaching virtio-net-pci $nic_id on $pf_dev from VM $hostname"
    cmd="device_del id=net$nic_id"
    $BASE_DIR/qmp.sh "$dir" "$cmd"
    if [ -n "$hook" ]; then
        echo "Executing hook script '$hook $dir $op $nic_id'"
        $hook "$dir" "$op" "$nic_id"
    fi
else
    echo "Wrong operation." >&2
    exit 4
fi
