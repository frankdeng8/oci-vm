#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -a [vm Hostname] -d [Ethernet PF device name]"
    echo "Options:"
    echo "  -a [vm hostname], available hostname:"
    echo "     ol1 - ol36 in vlan 617"
    echo "     vm1 - vm115 in tagged vlan $VLAN_ID"
    echo "  -P [VM working directory], default is ./<hostname>"
    echo "  -d [Ethernet device name], on which to create VF or macvtap device example: eno2"
    echo "  -n [virtio|vf], vnic: virtio-net or Virtual Function(SR-IOV), default is vf"
    echo "  -r macvtap or VF max_tx_rate, default is 0(unlimit), unit(Mb/s)"
    echo "Example: $0 -a ol1 -d eno2 -n vf -P ~/myvms/ol1"
}

hostname=
pf_dev=
max_tx_rate=0 #unlimit
dir=

vlan=

# nic mode, virtio or vf
nic_mode=vf

while getopts "a:d:n:r:P:h" OPTION; do
    case "$OPTION" in
      a)
        hostname=$OPTARG
        ;;
      d)
        pf_dev=$OPTARG
        ;;
      n)
        nic_mode=$OPTARG
        ;;
      r)
        max_tx_rate=$OPTARG
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

if [ -z "$hostname" ]; then
    echo "hostname not found" >&2
    usage
    exit 1
fi

if [[ "$hostname" == ol* ]]; then
    vlan=0
elif [[ "$hostname" == vm* ]]; then
    vlan=1
else
    echo "Wrong hostname $hostname" >&2
    usage
    exit 1
fi

if [ -z "$pf_dev" ]; then
    echo "Ethernet device not found" >&2
    usage
    exit 1
fi

# vm work dir
if [ -z "$dir" ]; then
    dir="./$hostname"
fi
# use abs path for vm work dir
dir=$(readlink -f "$dir")
mkdir -p "$dir"

# VFs should have been created
if ! ip link show $pf_dev >/dev/null; then
    echo "$pf_dev not found" >&2
    exit 1
fi

# MAC
mac=$(get_mac $hostname)

macvtap_dev=$(get_macvtap $hostname)
if [ -z "$macvtap_dev" ]; then
    echo "VM macvtap device not found."
    exit 3
fi
vf_id=$(get_vf $hostname $pf_dev)
if [ -z "$vf_id" ]; then
    echo "VM $hostname VF ID not found."
    exit 2
fi
vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
ipxe_boot=$(cat $dir/ipxe_boot)

if [ "$nic_mode" = virtio ]; then
    # create and bring up macvtap
    set_macvtap "$hostname" "$pf_dev" "$macvtap_dev" "$max_tx_rate"

    if $BASE_DIR/hmp.sh "$dir" "info status" 2>/dev/null; then
        efirom_file=$(get_efirom_file $dir $ipxe_boot 'virtio')
        # add netdev tap
        cmd="netdev_add tap,fds=10,id=hostnet0,vhost=on,vhostfds=11"
        $BASE_DIR/hmp.sh "$dir" "$cmd"
        # add virtio-net-pci
        cmd="device_add virtio-net-pci,vectors=4,netdev=hostnet0,id=net0,mac=$mac,standby=on,romfile=$efirom_file"
        $BASE_DIR/hmp.sh "$dir" "$cmd"
        get_info $dir "pci network"
    else
        echo "Failed." >&2
        exit 4
    fi

elif [ "$nic_mode" = vf ]; then
    # initialize vf
    set_vf "$hostname" "$pf_dev" "$max_tx_rate"
    # 1-(c) hot add a VF with "x-failover-primary" property set to true
    # dev_add vf
    if $BASE_DIR/hmp.sh "$dir" "info status" 2>/dev/null; then
        echo "Attaching vf $vf_id($vf_pci_addr) on $pf_dev to VM $hostname"
        #efirom_file=$(get_efirom_file $dir $ipxe_boot $vf_pci_addr)
        # do not add romfile as vm should be launched with virtio
        #cmd="device_add vfio-pci,host=$vf_pci_addr,id=vf0,romfile=$efirom_file"
        #cmd="device_add vfio-pci,host=$vf_pci_addr,id=vf0,x-failover-primary=true"
        #$BASE_DIR/hmp.sh "$dir" "$cmd"
        #cmd="device_add driver=vfio-pci host=$vf_pci_addr id=vf0"
        #cmd="device_add driver=vfio-pci host=$vf_pci_addr id=vf0 romfile=$efirom_file"
        cmd="device_add driver=vfio-pci host=$vf_pci_addr id=vf0 x-failover-primary=true"
        $BASE_DIR/qmp.sh "$dir" "$cmd"
        # 1-(d) once VF shows up in the guest, a corresponding FAILOVER_PRIMARY_CHANGED
        # vf "enabled" event will be emitted

        # At this point, VF may soon activate its MAC address filter in the NIC,
        # which will be conflict with the MAC filter being used by virtio.
        # Upon receiving this event, Hippovisor should remove the conflict MAC
        # filter for VF to activate its datapath later

        # TODO: check the event, vf enabed or vf disabled
        #  vf enable event, bring down macvtap
        #  vf disable event, bring up macvtap again
        read -p "press enter to continue"
        unset_macvtap $macvtap_dev

        get_info $dir "pci network"
    else
        echo "Failed." >&2
        exit 4
    fi
fi

