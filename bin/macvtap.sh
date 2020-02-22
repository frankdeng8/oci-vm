#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -P <vm working dir> -o [up|down]"
    echo "Options:"
    echo "  -P [VM working directory]"
    echo "  -d [Ethernet device name], on which to create VF or macvtap device example: eno2"
    echo "  -o [up|down], bring up or down macvtap device for a vm"
    echo "      up: ip link set macvtap up"
    echo "      down: ip link set macvtap down"
    echo "  -n nic id, 0 or 1, default 0"
    echo "  -r VF max_tx_rate, default is 0(unlimit), unit(Mb/s)"
    echo "Example: $0 -o up -P ~/myvms/ol1"
}

hostname=
pf_dev=
max_tx_rate=0 #unlimit
nic_id=0
dir=
op=

while getopts "o:r:P:n:h" OPTION; do
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
mac=$(get_mac $hostname $nic_id)

#macvtap
macvtap_dev=$(get_macvtap $hostname $nic_id)

if [ -z "$macvtap_dev" ]; then
    echo "VM macvtap device not found."
    exit 3
fi

if [ "$op" = set -o "$op" = up ]; then
    set_macvtap "$hostname" "$pf_dev" "$macvtap_dev" "$max_tx_rate" "$nic_id"
elif [ "$op" = unset -o "$op" = down ]; then
    unset_macvtap $macvtap_dev
else
    echo "Wrong operation." >&2
    exit 4
fi
