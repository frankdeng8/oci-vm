#!/bin/bash
set -e
#set -x
# usage:
usage () {
    echo "$0 -a <vm hostname> -d <ethernet dev> -D <dest host> -b <pv|iscsi>"
}

# vm hostname
vm=
memory=80000 # MB
cpu=16
# ethernet dev
pf_dev=
# dest host
dest_host=
# note: setup ssh passwordless between two hsots.

ipxe_boot=iscsi #iscsi or pv

while getopts "a:d:D:b:h" OPTION; do
    case "$OPTION" in
      a)
        vm=$OPTARG
        ;;
      d)
        pf_dev=$OPTARG
        ;;
      D)
        dest_host=$OPTARG
        ;;
      b)
        ipxe_boot=$OPTARG
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

if [ -z "$vm" -o -z "$pf_dev" -o -z "$dest_host" -o -z "$ipxe_boot" ]; then
    usage
    exit 1
fi

base_dir=$(dirname "$(readlink -f $0)")
SSH='/usr/bin/ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
vm_dir=~/vms/$vm

# this host
############## first start vm on this host
# start vm
echo "Starting VM on source host."
$base_dir/start.sh -a $vm -c $cpu -m $memory -P $vm_dir -d $pf_dev -n virtio -s -b $ipxe_boot -H &

# wait for vf added
echo "Checking VF is hot added."
while ! $base_dir/hmp.sh $vm_dir "info pci" 2>/dev/null |grep -q 'id "vf0"'; do
    sleep 1
done

echo "Checking macvtap is down."
# and macvtap should be down
macvtap_dev=$(cat $vm_dir/macvtap_dev)
while ! ip link show $macvtap_dev | grep -q 'state DOWN'; do
    sleep 1
done

#sleep 30

lm_count=0

migrate () {
    echo "Checking VM status on dest host is inmigrate."
    while ! $SSH $dest_host "$base_dir/hmp.sh $vm_dir 'info status' 2>/dev/null | grep -q 'VM status: paused (inmigrate)'"; do
        sleep 1
    done

    echo "Ready to start sr-iov lm."
    echo "Switching datapath to virtio_net."
    macvtap_dev=$(cat $vm_dir/macvtap_dev)
    vf_id=$(cat $vm_dir/vf_id)
    mac=$(cat $vm_dir/mac)
    # migrate
    # datapath switch to virtio
    echo "Hot removing VF."
    $base_dir/vf.sh -o del -P $vm_dir

    echo "Checking macvtap is up."
    # check macvtap is up
    while ! ip link show $macvtap_dev | grep -q 'state UP'; do
        sleep 1
    done

    # check vf is un-bound from vfio-pci

    echo "Checking VF is unset."
    # vf has no vm mac address
    c_mac=$(ip link show $pf_dev | grep "vf $vf_id " | awk '{print $4}' | sed 's/,//g')
    while [ "$mac" = "$c_mac" ]; do
        sleep 1
        c_mac=$(ip link show $pf_dev | grep "vf $vf_id " | awk '{print $4}' | sed 's/,//g')
    done
    # vf unbind from vfio-pci
    vf_pci_addr=$($base_dir/get_vf.sh $pf_dev $vf_id)
    while [ -h "/sys/bus/pci/drivers/vfio-pci/$vf_pci_addr" ]; do
        sleep 1
    done

    echo "Start live migration."
    # start migrate
    $base_dir/migrate.sh -P $vm_dir -d $dest_host

    # check migrate status
    echo "Checking migration status"
    while ! $base_dir/hmp.sh $vm_dir "info migrate" 2>/dev/null |grep -q 'Migration status: completed'; do
        sleep 2
    done
    $base_dir/hmp.sh $vm_dir info migrate

    lm_count=$(($lm_count+1))
    echo "SR-IOV live migration count: $lm_count"
    # dest host
    # check vm status

    # do not check dest host vm status
    #echo "Checking vm status on anonther host: running."
    #while ! $SSH $dest_host "$base_dir/hmp.sh $vm_dir 'info status' 2>/dev/null |grep -q 'VM status: running'"; do
    #    sleep 1
    #done

    echo "Stoping VM."
    $base_dir/stop.sh -P $vm_dir
    # wait for the background start.sh job
    set +e
    for job in $(jobs -p); do
        wait $job
    done
    set -e

    sleep 5

    echo "Starting VM in migration listen mode"
    $base_dir/start.sh -a $vm -c $cpu -m $memory -P $vm_dir -d $pf_dev -n virtio -s -b $ipxe_boot -H -I &

    echo "Checking VM status is inmigrate."
    while ! $base_dir/hmp.sh $vm_dir 'info status' 2>/dev/null | grep -q 'VM status: paused (inmigrate)'; do
        sleep 1
    done

    echo "Waiting for incoming migration."
    # do not check migrate status on dest host
    #echo "Checking migration status on another host"
    #while ! $SSH $dest_host "$base_dir/hmp.sh $vm_dir 'info migrate' 2>/dev/null | grep -q 'Migration status: completed'"; do
    #    sleep 1
    #done

    # once migration is competed, vm status changes to running
    echo "Waiting for VM status change to running."
    while ! $base_dir/hmp.sh $vm_dir 'info status' 2>/dev/null | grep -q 'VM status: running'; do
        sleep 1
    done

    echo "Live migration is done, switching datapath to VF."

    echo "Hot adding VF."
    $base_dir/vf.sh -o up -P $vm_dir
    time $base_dir/vf.sh -o add -p -P $vm_dir

    echo "Checking VF is added."
    while ! $base_dir/hmp.sh $vm_dir 'info pci' 2>/dev/null | grep -q 'id "vf0"'; do
        sleep 1
    done
    echo "Checking macvtap is down."
    while ! ip link show $macvtap_dev | grep -q 'state DOWN'; do
        sleep 1
    done
}

while true; do
    migrate
done
