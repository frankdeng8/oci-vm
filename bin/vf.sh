#!/bin/bash
set -e
#set -x

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -P <vm working dir> -o [up|down|add|del]"
    echo "Options:"
    echo "  -P [VM working directory]"
    echo "  -o [add|del|up|down], hot add or del vf"
    echo "      up: bind vf to vfio-pci, set vlan, mac, max_tx_rate"
    echo "      down: reset mac to 00:00:00:00:00:00, reset vlan, max_tx_rate, unbind vf from vfio-pci"
    echo "      add: QMP: device_add"
    echo "      del: QMP: device_del"
    echo "  -n nic id, 0 or 1, default 0"
    echo "  -p append 'x-failover-primary=true'"
    echo "  -r VF max_tx_rate, default is 0(unlimit), unit(Mb/s)"
    echo "Example: $0 -o add -n 1 -p -P ~/myvms/ol1"
}

hostname=
pf_dev=
max_tx_rate=0 #unlimit
nic_id=0
primary=0
dir=
op=

while getopts "o:r:P:n:ph" OPTION; do
    case "$OPTION" in
      o)
        op=$OPTARG
        ;;
      r)
        max_tx_rate=$OPTARG
        ;;
      n)
        nic_id=$OPTARG
        ;;
      P)
        dir=$OPTARG
        ;;
      p)
        primary=1
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
#mac=$(get_mac $hostname $nic_id)

# vf
vf_id=$(get_vf $hostname $pf_dev $nic_id)
if [ -z "$vf_id" ]; then
    echo "VM $hostname VF ID not found."
    exit 2
fi
vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
#ipxe_boot=$(cat $dir/ipxe_boot)

if [ "$op" = set -o "$op" = up ]; then
    set_vf "$hostname" "$pf_dev" "$max_tx_rate" "$nic_id"
elif [ "$op" = unset -o "$op" = down ]; then
    unset_vf $vf_pci_addr
elif [ "$op" = add ]; then
    # dev_add vf
    echo "Attaching vf $vf_id($vf_pci_addr) on $pf_dev to VM $hostname"
    #efirom_file=$(get_efirom_file $dir $ipxe_boot $vf_pci_addr)
    cmd="device_add driver=vfio-pci host=$vf_pci_addr id=vf$nic_id"
    if [ $primary -eq 1 ]; then
        cmd="$cmd x-failover-primary=true"
    fi
    $BASE_DIR/qmp.sh "$dir" "$cmd"
elif [ "$op" = del ]; then
    echo "Detaching vf $vf_id($vf_pci_addr) on $pf_dev from VM $hostname"
    cmd="device_del id=vf$nic_id"
    $BASE_DIR/qmp.sh "$dir" "$cmd"
else
    echo "Wrong operation." >&2
    exit 4
fi
