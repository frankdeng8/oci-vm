#!/bin/bash
set -e
#set -x

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -a [VM Hostname] -d [Ethernet device name]"
    echo "Options:"
    echo "  -a [VM hostname], available hostnames:"
    echo "     ol1 - ol36 in vlan 617"
    echo "     vm1 - vm115 in tagged vlan $VLAN_ID"
    echo "  -P [VM working directory], default: ./<vm hostname>"
    echo "  -p pause the VM before launching, the vm will enter into initial paused state(prelaunch)"
    echo "  -H start handle_events.py after launching the VM for SR-IOV live migration datapath switching"
    echo "  -I migration-listen mode, start vm with -incoming tcp:0:<port> on dst host for incoming migration"
    echo "  -c [number of ocpus], default: $cpu_num"
    echo "  -m [memory size in MB], default: $memory MB"
    echo "  -d [Ethernet device name], must support SR-IOV, on which create VFs or macvtap device example: eno2"
    echo "  -v enable VEPA on PF"
    echo "  -b [iscsi|pv], boot volume, iSCSI boot inside VM or PV(virtio-scsi-pci/scsi-block), default: iscsi"
    echo "  -n [virtio|vf|none], nic: virtio-net or Virtual Function(SR-IOV) or none, default: vf"
    echo "         when nic is none and boot volume is iscsi, the vm will be put in paused(prelaunch) state"
    echo "  -s start virtio-net nic with standby=on"
    echo "  -N [number of nic], 1 or 2, default 1"
    echo "  -r [max_tx_rate], macvtap or VF max_tx_rate, default is 0(unlimit), unit(Mb/s)"
    # temporarily disable iscsi target ip
    #echo "  -t [iSCSI target IP address], default is $TARGET_IP or $TARGET_IP_VLAN in tagged vlan $vlan_id"
    echo "  -i [customized ipxe script file], default is boot-iscsi.ipxe.template or boot-pv.ipxe.template"
    echo
    echo "Samples:"
    echo "  -Start a VM(iSCSI boot volume) with a vfio nic"
    echo "       $0 -a ol1 -d eno2 -b iscsi -n vf -P ~/vms/ol1"
    echo "  -Start a VM(PV boot volume) with a virtio-net nic"
    echo "       $0 -a ol1 -d eno2 -b pv -n virtio -P ~/vms/ol1"
    echo "  -Start a VM(iSCSI boot volume) with a standby enabled virtio-net nic"
    echo "       $0 -a ol1 -d eno2 -b iscsi -n virtio -s -P ~/vms/ol1"
    echo "  -Start a VM(PV boot volume) with a standby enabled virtio-net nic,"
    echo "   and handle SR-IOV datapath switching events"
    echo "       $0 -a vm1 -d eno2 -b pv -n virtio -s -H -P ~/vms/vm1"
    echo "  -Start a VM(iSCSI boot volume) with a standby enabled virtio-net nic in migration listen mode,"
    echo "   and handle SR-IOV datapath switching events"
    echo "       $0 -a vm1 -d eno2 -b iscsi -n virtio -s -I -H -P ~/vms/vm1"
    echo "  -Create a VM(iSCSI boot volume) with a vfio nic, VM will enter into prelaunch state"
    echo "       $0 -a vm1 -d eno2 -b iscsi -n vf -p -P ~/vms/vm1"
    echo "  -Create a VM(PV boot volume) without net device, VM will enter into prelaunch state"
    echo "       $0 -a vm1 -d eno2 -b pv -n none -p -P ~/vms/vm1"
    echo "More details see https://confluence.oraclecorp.com/confluence/display/OLHST/Launch+VM+from+OCI+images"
}

# start VM
# args:
# $1 - vm work dir
# $2 - pause, 0 or 1
# $3 - migration listen, 0 or 1
# $4 - handle events, 0 or 1
# $5 - ocpu #
# $6 - memory in MB
# $7 - boot_volume - iscsi, pv
# $8 - nic - vf, virtio, or none
# $9 - nic num - num of nics
# $10 - virtio_net standby=on? 0 or 1
# $11 - customized ipxe boot, 0 or 1
start_vm() {
    local dir=$1
    shift
    local pause=$1
    shift
    local handle_events=$1
    shift
    local migration_listen=$1
    shift
    local cpu=$1
    shift
    local memory=$1
    shift
    local boot_volume=$1
    shift
    local nic=$1
    shift
    local nic_num=$1
    shift
    local virtio_net_standby=$1
    shift
    local customized_ipxe=$1

    local target_ip=
    local vnc_port=

    #echo $*
    local args

    # default args, most args obtained from OCI
    args="    -no-user-config
    -nodefaults
    -no-shutdown
    -machine accel=kvm,usb=on
    -rtc base=utc"

    # cpu and memory
    # ocpu: cpu = cores
    local s_smp=
    if [ $cpu -eq 1 ]; then
        s_smp="cpus=1,cores=1,threads=1,sockets=1"
    else
        s_smp="cpus=$(($cpu*2)),cores=$cpu,threads=2,sockets=1"
    fi
    args="$args
    -m $memory
    -cpu host
    -smp $s_smp"

    # vnc, serial console, monitors
    local vnc_port=$(get_vnc_port $hostname)
    args="$args
    -display vnc=:$vnc_port
    -display vnc=unix:$dir/write-qemu/vnc.sock
    -vga std
    -chardev socket,id=serial0,server,path=$dir/write-qemu/serial.sock,nowait
    -device isa-serial,chardev=serial0
    -chardev socket,id=monitor0,server,path=$dir/write-qemu/monitor.sock,nowait
    -mon monitor0,mode=control
    -chardev socket,id=monitor1,server,path=$dir/write-qemu/monitor-debug.sock,nowait
    -mon monitor1,mode=control
    -chardev socket,id=monitor2,server,path=$dir/write-qemu/monitor-macvtap.sock,nowait
    -mon monitor2,mode=control
    -chardev socket,id=monitor3,server,path=$dir/write-qemu/monitor-event.sock,nowait
    -mon monitor3,mode=control"
    #args="$args
    #-monitor stdio"
    args="$args
    -D $dir/qemu.log"

    # uuid and smbios, uefi
    local uuid=$(get_uuid $hostname)
    #-smbios type=1,serial=ds=nocloud-net;seedfrom=http://10.197.0.4/systest/public/seed/
    #-smbios type=1,serial=ds=nocloud;seedfrom=/
    args="$args
    -uuid $uuid
    -smbios type=3,asset=OracleCloud.com
    -drive file=$dir/read-qemu/OVMF_CODE.fd,index=0,if=pflash,format=raw,readonly
    -drive file=$dir/read-qemu/OVMF_VARS.fd,index=1,if=pflash,format=raw,readonly"
    # OVMF_VARS.fd may need to set writeable

    # pause to initial state(prelaunch) or not
    if [ "$pause" = 1 ]; then
        args="$args
    -S"
    fi
    # listen for incoming migration
    if [ "$migration_listen" = 1 ]; then
        local migration_port=$(get_migration_port $hostname)
        args="$args
    -incoming tcp:0:$migration_port"
    fi

    # devices

    # usb
    args="$args
    -device usb-tablet"

    # vf and macvtap that should already be ready
    local vf_id=$(get_vf $hostname $pf_dev)
    local vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)

    local macvtap_dev=$(get_macvtap $hostname)
    local tap_id=$(get_tap_id $macvtap_dev)

    local mac=$(get_mac $hostname)

    if [ "$nic_num" = 2 ]; then
        local vf1_id=$(get_vf $hostname $pf_dev 1)
        local vf1_pci_addr=$(get_vf_pci_addr $pf_dev $vf1_id)
        local macvtap1_dev=$(get_macvtap $hostname 1)
        local tap1_id=$(get_tap_id $macvtap1_dev)
        local mac1=$(get_mac $hostname 1)

    fi

    # ipxe boot options:  iscsi, pv, customized
    local ipxe_boot=
    if [ "$customized_ipxe" = 1 ]; then
        ipxe_boot=customized
    else
        ipxe_boot=$boot_volume
    fi

    # nic: vf or virtio
    if [ "$nic" = vf ]; then
        local efirom_file=$(get_efirom_file $dir $ipxe_boot $vf_pci_addr)
        args="$args
    -device vfio-pci,host=$vf_pci_addr,id=vf0"
    #-device vfio-pci,host=$vf_pci_addr,id=vf0,romfile=$efirom_file"

        # add romfile for iscsi boot
        if [ "$boot_volume" = iscsi ]; then
            args="$args,romfile=$efirom_file"
        fi

        # do not set booindex for pv boot
        # iscsi boot with 2 nics, set bootindex=? for vf
        if [ "$boot_volume" = iscsi ]; then
            args="$args,bootindex=1"
        fi

        if [ "$nic_num" = 2 ]; then
            args="$args
    -device vfio-pci,host=$vf1_pci_addr,id=vf1"
        fi
    fi

    # fds need to be passed to virtio args
    local tap_fd=$TAP_FD
    local tap1_fd=$TAP1_FD
    local vhost_net_fd=$VHOST_NET_FD
    local vhost_net1_fd=$VHOST_NET1_FD

    if [ "$nic" = virtio ]; then
        local efirom_file=$(get_efirom_file $dir $ipxe_boot 'virtio')
        args="$args
    -netdev tap,fds=$tap_fd,id=hostnet0,vhost=on,vhostfds=$vhost_net_fd
    -device virtio-net-pci,vectors=4,netdev=hostnet0,id=net0,mac=$mac"
    #-device virtio-net-pci,vectors=4,netdev=hostnet0,id=net0,mac=$mac,romfile=$efirom_file"

        # add romfile for iscsi boot
        if [ "$boot_volume" = iscsi ]; then
            args="$args,romfile=$efirom_file"
        fi
    #-device virtio-net-pci,vectors=4,netdev=hostnet0,bus=pci.0,addr=0x3,id=net0,mac=$mac,romfile=$efirom_file"
    #-device virtio-net-pci,vectors=4,bus=pci.0,addr=0x3,netdev=hostnet0,id=net0,mac=$mac,romfile=$efirom_file"
        # enable standby feature for virtio_net
        if [ "$virtio_net_standby" -eq 1 ]; then
            args="$args,standby=on"
        fi
        # do not set booindex for pv boot
        # iscsi boot with 2 nics, set bootindex=? for virtio-net
        if [ "$nic_num" = 2 -a "$boot_volume" = iscsi ]; then
            args="$args,bootindex=1"
        fi
        if [ "$nic_num" = 2 ]; then
            args="$args
    -netdev tap,fds=$tap1_fd,id=hostnet1,vhost=on,vhostfds=$vhost_net1_fd
    -device virtio-net-pci,netdev=hostnet1,id=net1,mac=$mac1"
    #-device virtio-net-pci,netdev=hostnet1,bus=pci.0,addr=0x4,id=net1,mac=$mac1,romfile="
    #-device virtio-net-pci,netdev=hostnet1,id=net1,mac=$mac1,romfile=$efirom_file"
    #-device virtio-net-pci,bus=pci.0,addr=0x4,netdev=hostnet1,id=net1,mac=$mac1"
            # enable standby feature for virtio_net
            if [ "$virtio_net_standby" -eq 1 ]; then
                args="$args,standby=on"
            fi
            if [ "$nic_num" = 2 -a "$boot_volume" = iscsi ]; then
                args="$args,bootindex=2"
            fi
            # no network for 2nd nic
            unset_macvtap $macvtap1_dev
        fi
    fi

    # pv boot volume: qemu/libiscsi
    if [ "$boot_volume" = pv ]; then
        # use dedicate vlan $PV_VLAN_ID for iscsi connection
        #local target_ip=$(get_target_ip $hostname)
        #local target_ip=$TARGET_IP
        local target_ip=$TARGET_IP_PV_VLAN
        # virtio-scsi-pci controller id: virtio-scsi-pci0
        # iscsi target password id: sec0
        # iscsi block device node-name: iscsi-$target_ip
        # scsi-block devcie id: scsi-block0
        # virtio-scsi-pci disk controller, one controller for each VM instance
        args="$args
    -device virtio-scsi-pci,id=virtio-scsi-pci0"
        # qom object that is used by qemu to login to the iSCSI drive
        args="$args
    -object qom-type=secret,id=sec0,data=guest"
        # Add a backend driver so that qemu can login to the iSCSI drive
        #args="$args
    #-blockdev driver=iscsi,transport=tcp,portal=$target_ip:3260,target=iqn.2015-02.oracle.boot:uefi,lun=1,node-name=iscsi-$target_ip,cache.no-flush=off,cache.direct=on,read-only=off,user=guest,password-secret=sec0,initiator-name=iqn.2015-02.oracle.boot:$hostname"
        # removed user and password for iSCSI login, add initiator-name.
        args="$args
    -blockdev driver=iscsi,transport=tcp,portal=$target_ip:3260,target=iqn.2015-02.oracle.boot:uefi,lun=0,node-name=iscsi-$target_ip,cache.no-flush=off,cache.direct=on,read-only=off,initiator-name=iqn.2015-02.oracle.boot:$hostname"
        # The PV volume that is virtualized for the instance as scsi-block
        args="$args
    -device scsi-block,bus=virtio-scsi-pci0.0,id=scsi-block0,drive=iscsi-$target_ip"

        # PV boot, specify boot order from hard disk
        args="$args
    -boot order=c"
    fi

    # qemu args done.

    # write info to <vm working dir>
    echo "$hostname" > $dir/hostname
    echo "$nic" > $dir/nic
    echo "$macvtap_dev" > $dir/macvtap_dev
    echo "$pf_dev" > $dir/pf_dev
    echo "$vf_id" > $dir/vf_id
    echo "$mac" > $dir/mac
    if [ "$nic_num" = 2 ]; then
        echo "$mac1" > $dir/mac1
        echo "$vf1_id" > $dir/vf1_id
        echo "$macvtap1_dev" > $dir/macvtap1_dev
    fi
    echo "$ipxe_boot" > $dir/ipxe_boot
    echo "$boot_volume" > $dir/boot_volume
    echo "$args" > $dir/args

    # open fds for tap and vhost-net
    echo "Openning FDs:"
    echo "  $tap_fd<>/dev/tap$tap_id $vhost_net_fd<>/dev/vhost-net"
    eval "exec $tap_fd<>/dev/tap$tap_id"
    eval "exec $vhost_net_fd<>/dev/vhost-net"
    if [ "$nic_num" = 2 ]; then
        echo "  $tap1_fd<>/dev/tap$tap1_id $vhost_net1_fd<>/dev/vhost-net"
        eval "exec $tap1_fd<>/dev/tap$tap1_id"
        eval "exec $vhost_net1_fd<>/dev/vhost-net"
    fi
    # write fd info to <vm working dir>
    echo "$tap_fd /dev/tap$tap_id" > $dir/fd
    echo "$vhost_net_fd /dev/vhost-net" >> $dir/fd
    if [ "$nic_num" = 2 ]; then
        echo "$tap1_fd /dev/tap$tap_id" >> $dir/fd
        echo "$vhost_net1_fd /dev/vhost-net" >> $dir/fd
    fi

    # print vm information
    echo "Starting VM $hostname with:"
    echo "  ocpu: $cpu"
    echo "  memory: $memory MB"
    echo "  boot volume: $boot_volume"
    echo "  nic: $nic"
    echo "  qemu-system-x86_64 args:"
    echo "$args"
    if [ "$pause" = 1 ]; then
        echo "VM will enter into paused(prelaunch) state."
        echo "  Use attach.sh to attach virtio or VF device if needed"
        echo "  Use cont.sh to unpause(launch) VM"
    fi
    if [ "$migration_listen" = 1 ]; then
        echo "VM will enter into migration listen mode, listen port $migration_port"
        echo "  Use migrate.sh to migrate the vm from source host to this host"
    fi
    echo "To access VM serial console:"
    #echo "  # socat - $dir/write-qemu/serial.sock"
    echo "  # ./serial.sh $dir"
    echo "To access VM vnc console:"
    echo "  # vncviewer $HOSTNAME:$vnc_port"
    echo

    if [ "$handle_events" -eq 1 ]; then
        /usr/bin/qemu-system-x86_64 $args &
        local qemu_pid=$!
        sleep 1
        $BASE_DIR/handle_events.py -P "$dir"
        wait $qemu_pid
    else
        /usr/bin/qemu-system-x86_64 $args
    fi

    # other args FYI:

    # ring buf serial console - obsoleted by OCI
    # -chardev ringbuf,id=ringBufSerial0,size=8388608
    # -device isa-serial,chardev=ringBufSerial0

    # boot from network:
    # -boot order=n

    # vfio
    # -device vfio-pci,host=$vf_pci_addr,id=vf0,romfile=$dir/qemu-img-binaries/$vf_rom"

    # virtio-net
    # -device virtio-net-pci,vectors=4,netdev=net33,romfile=,mac=02:00:17:01:A7:44
    # -netdev tap,id=net33,vhostfds=11,fds=10

    # boot order:
    # -boot order=n

    # metadata
    #-drive file=metadata.iso,media=cdrom,id=cdrom0 \

    # virtio block
    #-drive file=/home/vm/ol7_${index}.qcow2,format=qcow2,if=virtio,id=drive-virtio-disk0 

    # bnxt vf pri
    #-net none -device vfio-pci,host=0000:3b:11.7,romfile=qemu-img-binaries/snp.efirom

    # ixgbe vf
    # -net none -device vfio-pci,host=0000:18:1f.5,romfile=qemu-img-binaries/80861515.efirom

    # cdrom
    #-cdrom OracleLinux-R7-U3-Server-x86_64-dvd.iso \
}

hostname=
pf_dev=
cpu_num=2
memory=2048 #MB
max_tx_rate=0 #unlimit
dir=

vlan=0 # 1 - tagged vlan

# boot_volume, pv, iscsi, default: iscsi
boot_volume=iscsi

# nic mode, virtio or vf or none, default: vf
nic=vf

# nic num
nic_num=1

# enable vepa on PF?
vepa=0

# enable virtio-net standby feature. 1 - enable
virtio_net_standby=0
# pause vm, 1 - pause
pause=0

# handle events after launching vm
handle_events=0

# migration listen mode, 1 - listen mode
migration_listen=0

# use customized ipxe script?
customized_ipxe=0
customized_ipxe_script_template=

while getopts "a:P:pHIc:m:d:vb:n:N:sr:i:h" OPTION; do
    case "$OPTION" in
      a)
        hostname=$OPTARG
        ;;
      P)
        dir=$OPTARG
        ;;
      p)
        pause=1
        ;;
      H)
        handle_events=1
        ;;
      I)
        migration_listen=1
        ;;
      c)
        cpu_num=$OPTARG
        ;;
      m)
        memory=$OPTARG
        ;;
      d)
        pf_dev=$OPTARG
        ;;
      v)
        vepa=1
        ;;
      b)
        boot_volume=$OPTARG
        ;;
      n)
        nic=$OPTARG
        ;;
      N)
        nic_num=$OPTARG
        ;;
      s)
        virtio_net_standby=1
        ;;
      r)
        max_tx_rate=$OPTARG
        ;;
      i)
        customized_ipxe_script_template=$OPTARG
        customized_ipxe=1
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
    echo "VM hostname not found" >&2
    usage
    exit 1
fi

if [ "$nic_num" != 1 -a "$nic_num" != 2 ]; then
    echo "Wrong nic number" >&2
    usage
    exit 1
fi

if [[ "$hostname" == ol* ]]; then
    vlan=0
elif [[ "$hostname" == vm* ]]; then
    vlan=1
else
    echo "Wrong VM hostname $hostname" >&2
    usage
    exit 1
fi

if [ -z "$pf_dev" ]; then
    echo "Ethernet device must be specified." >&2
    usage
    exit 1
fi

if ! ip link show "$pf_dev" >/dev/null 2>&1; then
    echo "Ethernet device $pf_dev not found." >&2
    exit 1
fi

if [ "$boot_volume" != iscsi -a "$boot_volume" != pv ]; then
    echo "Unknown boot volume."
    usage
    exit 1
fi

if [ "$nic" != vf -a "$nic" != virtio -a "$nic" != none ]; then
    echo "Unknown nic type."
    usage
    exit 1
fi

if [ -n "$customized_ipxe_script_template" -a ! -f "$customized_ipxe_script_template" ]; then
    echo "Customized ipxe script $customized_ipxe_script_template not found" >&2
    usage
    exit 1
fi

check

# vm work dir
if [ -z "$dir" ]; then
    dir="./$hostname"
fi

mkdir -p "$dir"
# use abs path for vm work dir
dir=$(readlink -f "$dir")

# initialize the network

# Enable VEPA
if [ $vepa -eq 1 ]; then
    echo "Enabling VEPA on $pf_dev"
    bridge link set dev $pf_dev hwmode vepa
fi

# Enable SR-IOV, create VFs
echo "Creating VFs."
if ! $BASE_DIR/create_vf.sh -d $pf_dev; then
    echo "Failed to create VFs on $pf_dev"
    exit 2
fi

# reserve a pair of VF and macvtap devices for nic 0
vf_id=$(get_vf $hostname $pf_dev)
if [ -n "$vf_id" ]; then
    vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
    echo "Found vf id $vf_id on $pf_dev"
else
    # get a free vf
    vf_id=$(find_vf $pf_dev)
    if [ "$vf_id" -lt 0 ]; then
        echo "Failed to find a valid VF" >&2
        exit 3
    fi
    vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
    # TODO: to avoid vf is reserved by multiple VMs by locking the vf list file
    reserve_vf $hostname $pf_dev $vf_id $vf_pci_addr
    echo "Reserved new vf id $vf_id on $pf_dev"
fi

macvtap_dev=$(get_macvtap $hostname)
if [ -n "$macvtap_dev" ]; then
    echo "Found macvtap ${macvtap_dev}@${pf_dev}"
else
    # get a new macvtap
    macvtap_dev=$(find_macvtap)
    # TODO: to avoid tap device is reserved by multiple VMs by locking the tap list file
    reserve_macvtap $hostname $pf_dev $macvtap_dev
    echo "Reserved new macvtap ${macvtap_dev}@${pf_dev}"
fi

# second pair of VF and macvtap for nic 1
vf1_id=$(get_vf $hostname $pf_dev 1)
if [ -n "$vf1_id" ]; then
    vf1_pci_addr=$(get_vf_pci_addr $pf_dev $vf1_id)
    echo "Found vf id $vf1_id on $pf_dev"
else
    # get a free vf
    vf1_id=$(find_vf $pf_dev)
    if [ "$vf1_id" -lt 0 ]; then
        echo "Failed to find a valid VF" >&2
        exit 3
    fi
    vf1_pci_addr=$(get_vf_pci_addr $pf_dev $vf1_id)
    # TODO: to avoid vf is reserved by multiple VMs by locking the vf list file
    reserve_vf $hostname $pf_dev $vf1_id $vf1_pci_addr 1
    echo "Reserved new vf id $vf1_id on $pf_dev"
fi
macvtap1_dev=$(get_macvtap $hostname 1)
if [ -n "$macvtap1_dev" ]; then
    echo "Found macvtap ${macvtap1_dev}@${pf_dev}"
else
    # get a new macvtap
    macvtap1_dev=$(find_macvtap)
    # TODO: to avoid tap device is reserved by multiple VMs by locking the tap list file
    reserve_macvtap $hostname $pf_dev $macvtap1_dev 1
    echo "Reserved new macvtap ${macvtap1_dev}@${pf_dev}"
fi

# unset and release vf when something is wrong or script exits.
# delete and release macvtap when something is wrong or script exits.
#trap "clean_nic $vf_pci_addr $macvtap_dev" SIGINT SIGTERM SIGQUIT EXIT
trap "clean_nics $hostname $pf_dev" SIGINT SIGTERM SIGQUIT EXIT

# pre-set the vf or macvtap
# create and initialize vf
set_vf "$hostname" "$pf_dev" "$max_tx_rate" 0
# create and bring up macvtap
if ! set_macvtap "$hostname" "$pf_dev" "$macvtap_dev" "$max_tx_rate" 0; then
    exit 2
fi
# second nic
set_vf "$hostname" "$pf_dev" "$max_tx_rate" 1
if ! set_macvtap "$hostname" "$pf_dev" "$macvtap1_dev" "$max_tx_rate" 1; then
    exit 2
fi

if [ "$nic" = none ]; then
    unset_vf $vf_pci_addr
    unset_vf $vf1_pci_addr
    unset_macvtap $macvtap_dev
    unset_macvtap $macvtap1_dev
elif [ "$nic" = vf ]; then
    # unset macvtap
    unset_macvtap $macvtap_dev
    unset_macvtap $macvtap1_dev
elif [ "$nic" = virtio ]; then
    # unset vf
    unset_vf $vf_pci_addr
    unset_vf $vf1_pci_addr
fi

# when nic is none, and boot volume is iSCSI, pause the vm, attach nic in prelaunch state
if [ "$nic" = none -a "$boot_volume" = iscsi ]; then
    pause=1
fi

# other vm configuration

# read-qemu: efi rom files, OVMF fds.
mkdir -p $dir/read-qemu
# write-qemu: serial, vnc, monitor socks
mkdir -p $dir/write-qemu

#download ovmf files and copy them to <vm working dir>/read-qemu
if [ ! -f "$dir/read-qemu/OVMF_VARS.fd" -o ! -f "$dir/read-qemu/OVMF_CODE.fd" ]; then
    echo "Dowlading OVMF ROM files from $QEMU_IMAGE_BINARIES"
    curl $QEMU_IMAGE_BINARIES | tar -xzf - -C $dir \
        qemu-img-binaries/OVMF_CODE.fd qemu-img-binaries/OVMF_VARS.fd
  /bin/cp -f $dir/qemu-img-binaries/* $dir/read-qemu
fi

# build ipxe rom files with all ipxe boot scripts: iscsi, pv, customized
# 1. iSCSI boot script template: boot-iscsi.ipxe.template
# 2. PV boot script template: boot-pv.ipxe.template
# 3. custommized

# ipxe efi rom file locations, example: snp.efirom
# <vm working dir>/read-qemu/iscsi/snp.efirom
# <vm working dir>/read-qemu/pv/snp.efirom
# <vm working dir>/read-qemu/customized/snp.efirom

# iscsi target ip
target_ip=$(get_target_ip $hostname)

ipxe_boot_modes="iscsi pv customized"
for ipxe_boot in $ipxe_boot_modes; do
    if [ "$ipxe_boot" = iscsi -o "$ipxe_boot" = pv ]; then
        ipxe_template=$BASE_DIR/boot-${ipxe_boot}.ipxe.template
    else
        ipxe_template=$customized_ipxe_script_template
    fi
    ipxe_file=$dir/boot-${ipxe_boot}.ipxe
    out_dir=$dir/read-qemu/$ipxe_boot
    mkdir -p "$out_dir"
    # do not build rom files if they are already built
    if [ ! -f "$ipxe_file" ]; then
        if [ -f "$ipxe_template" ]; then
            /bin/cp -f "$ipxe_template" $ipxe_file
            sed -i "s/{{HOSTNAME}}/$hostname/g" $ipxe_file
            sed -i "s/{{TARGET_IP}}/$target_ip/g" $ipxe_file
            echo "Building iPXE ROM files with embedded script $ipxe_file."
            echo "Check build log at $dir/ipxe_build.log"
            $BASE_DIR/build_ipxe_romfiles.sh $dir $out_dir $BASE_DIR/vendor_devices $ipxe_file

        fi
    fi
done

# start the VM
start_vm $dir $pause $handle_events $migration_listen $cpu_num $memory $boot_volume $nic $nic_num $virtio_net_standby $customized_ipxe
