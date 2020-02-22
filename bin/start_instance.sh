#!/bin/bash
set -e

#get mac
get_mac () {
    local prefix=$1
    local hostname=$2
    #local id=${hostname##ol}
    local id=${hostname[@]:2}
    local index=$((($id-1)*2))
    echo -n $prefix
    #printf "%04x\n" $index | sed -e 's/\(..\)/:\1/g'
    printf "%04x" $index | sed -e 's/\(..\)/:\1/g'
}

# get an unused VF
get_vf () {
    local pf_dev=$1
    local vf_pci_addr=

    local vf_id=0
    local vf_pci_addr=$($BASE_DIR/get_vf.sh $pf_dev $vf_id)
    if [ -z "$vf_pci_addr" ]; then
        echo $INVALID_VF_ID
        return
    fi
    while ps -ef |grep qemu-system-x86_64 | grep -q "host=$vf_pci_addr" || ([ -f $USED_VFS ] && grep -q $vf_pci_addr $USED_VFS); do
        vf_id=$(($vf_id+1))
        vf_pci_addr=$($BASE_DIR/get_vf.sh $pf_dev $vf_id)
    done

    local max_vf=$(get_max_vf $pf_dev)
    if [ $(($vf_id+1)) -ge $max_vf ]; then
        echo $INVALID_VF_ID
    else
        #$BASE_DIR/bind_vfio-pci.sh $vf_pci_addr
        echo $vf_pci_addr >> $USED_VFS
        echo $vf_id
    fi
}

release_vf () {
    set +e
    local vf_pci_addr=$1
    if [ -n "$pf_dev" -a -n "$vf_id" ]; then
        ip link set dev $pf_dev vf $vf_id vlan 0
        if [ -n "$mac" ]; then
            ip link set dev $pf_dev vf $vf_id mac 00:00:00:00:00:01 spoofchk off
            ip link set dev $pf_dev vf $vf_id  max_tx_rate 0 
        fi
    fi
    $BASE_DIR/unbind_vfio-pci.sh $vf_pci_addr
    sed -i "/$vf_pci_addr/d" $USED_VFS
}

get_vf_rom_file () {
    local dir=$1
    local pcidev=$2
    local vendor=$(cat /sys/bus/pci/devices/$pcidev/vendor)
    local device=$(cat /sys/bus/pci/devices/$pcidev/device)
    local rom_name=${vendor##0x}${device##0x}
    if [ -f "$dir/qemu-img-binaries/$rom_name.efirom" ]; then
        echo $rom_name.efirom
    else
        echo snp.efirom
    fi
}

get_max_vf () {
    local eth_dev=$1
    if [ -f/sys/class/net/$eth_dev/device/sriov_numvfs ]; then
        cat /sys/class/net/$eth_dev/device/sriov_numvfs
    else
        echo 0
    fi
}

start_instance () {

    local dir=$1
    local cpu=$2
    local memory=$3
    local vf_pci_addr=$4 # TODO multiple VFs
    local vnc_port=$5

    local s_cpu=
    if [ $cpu -eq 1 ]; then
        s_cpu="-smp cpus=1,cores=1,threads=1,sockets=1"
    else
        s_cpu="-smp cpus=$(($cpu*2)),cores=$cpu,threads=2,sockets=1"
    fi

    local vf_rom=$(get_vf_rom_file $dir $vf_pci_addr)

    local args="
    -no-user-config
    -nodefaults
    -no-shutdown
    -machine accel=kvm
    -rtc base=utc
    -m $memory
    -cpu host
    $s_cpu
    -display vnc=:$vnc_port
    -display vnc=unix:$dir/write-qemu/vnc.sock
    -vga std
    -chardev socket,id=serial0,server,path=$dir/write-qemu/serial.sock,nowait
    -device isa-serial,chardev=serial0
    -chardev ringbuf,id=ringBufSerial0,size=8388608
    -device isa-serial,chardev=ringBufSerial0
    -chardev socket,id=monitor0,server,path=$dir/write-qemu/monitor.sock,nowait
    -mon monitor0,mode=control
    -chardev socket,id=monitor1,server,path=$dir/write-qemu/monitor-debug.sock,nowait
    -mon monitor1,mode=control
    -boot order=n
    -drive file=$dir/qemu-img-binaries/OVMF_CODE.fd,index=0,if=pflash,format=raw,readonly
    -drive file=$dir/qemu-img-binaries/OVMF_VARS.fd,index=1,if=pflash,format=raw
    -device vfio-pci,host=$vf_pci_addr,id=vf0,romfile=$dir/qemu-img-binaries/$vf_rom"

    echo "Starting VM with [cores:$cpu, memory: $memory MB,  VNC: $HOSTNAME:$vnc_port]"
    echo "qemu-system-x86_64 args:$args"
    echo "To access VM serial console:"
    echo "  # socat - $dir/write-qemu/serial.sock"
    echo "To access VM vnc console:"
    echo "  # vncviewer $HOSTNAME:$vnc_port"
    echo

    /usr/bin/qemu-system-x86_64 $args

    # /usr/bin/qemu-system-x86_64 \
    # -no-user-config \
    # -nodefaults \
    # -no-shutdown \
    # -machine accel=kvm,mem-merge=off \
    # -rtc base=utc \
    # -m $memory \
    # $s_cpu \
    # -display vnc=:$vnc_port \
    # -vga std \
    # -chardev ringbuf,id=ringBufSerial0,size=8388608 \
    # -device isa-serial,chardev=ringBufSerial0 \
    # -chardev socket,id=monitor0,server,path=$dir/write-qemu/monitor-debug.sock,nowait \
    # -mon monitor0,mode=control \
    # -chardev socket,id=monitor1,server,path=$dir/write-qemu/monitor.sock,nowait \
    # -mon monitor1,mode=control \
    # -boot order=n \
    # -drive file=$dir/qemu-img-binaries/OVMF_CODE.fd,index=0,if=pflash,format=raw,readonly \
    # -drive file=$dir/qemu-img-binaries/OVMF_VARS.fd,index=1,if=pflash,format=raw \
    # -net none -device vfio-pci,host=$vf_pci_addr,romfile=$dir/qemu-img-binaries/$vf_rom

    # metadata
    #-drive file=metadata.iso,media=cdrom,id=cdrom0 \

    # virtio
    #-drive file=/home/vm/ol7_${index}.qcow2,format=qcow2,if=virtio,id=drive-virtio-disk0 

    # bnxt vf pri
    #-net none -device vfio-pci,host=0000:3b:11.7,romfile=qemu-img-binaries/snp.efirom

    # ixgbe vf
    # -net none -device vfio-pci,host=0000:18:1f.5,romfile=qemu-img-binaries/80861515.efirom

    #-drive file=ovmf_bmcs_bnxt/OVMF_CODE.fd,index=0,if=pflash,format=raw,readonly \
    #-drive file=ovmf_bmcs_bnxt/OVMF_VARS.fd,index=1,if=pflash,format=raw \
    #-drive file=qemu-img-binaries/OVMF_CODE.fd,index=0,if=pflash,format=raw,readonly \
    #-drive file=qemu-img-binaries/OVMF_VARS.fd,index=1,if=pflash,format=raw \

    #-net none -device vfio-pci,host=0000:3b:11.7,romfile=qemu-img-binaries/snp.efirom

    #-net none -device vfio-pci,host=0000:3b:11.7,romfile=./14e416e1.efirom.bmcs

    #-drive file=/usr/share/edk2.git/ovmf-x64/OVMF_CODE-pure-efi.fd,index=0,if=pflash,format=raw,readonly \
    #-drive file=/usr/share/edk2.git/ovmf-x64/OVMF_VARS-pure-efi.fd,index=1,if=pflash,format=raw,readonly \

    #-device vfio-pci,host=0000:3a:10.1,romfile=./80861515.efirom.bmcs  \
    #-device vfio-pci,host=0000:3a:10.3,romfile=./80861515.efirom.bmcs

    #-no-user-config \
    #-nodefaults \
    #-display vnc=unix:/write-qemu/vnc.sock \
    #-vga std \
    #-S \

    #-cdrom OracleLinux-R7-U3-Server-x86_64-dvd.iso \
    #-drive file=/home/vm/SnpDxe.efi,index=0,format=raw,readonly \
}

usage () {
    echo "Usage:"
    echo "$0 -n [Hostname] -d [Ethernet PF device name]"
    echo "Options:"
    echo "  -n [hostname], available hostname:"
    echo "     ol1 - ol36 in vlan 617"
    echo "     vm1 - vm115 in tagged vlan $vlan_id"
    echo "  -d [Ethernet PF device name], example: eno2"
    echo "  -p [VM working directory], default is ./<hostname>"
    echo "  -t [iSCSI target IP address], default is $TARGET_IP or $TARGET_IP_VLAN in tagged vlan $vlan_id"
    echo "  -v number of ethernet VFs, default is $vf_num"
    echo "  -c number of cpus, default is $cpu_num"
    echo "  -m memory, default is $memory MB"
    echo "  -r VF max_tx_rate, default is 0(unlimit), unit(Mb/s)"
    echo "  -i ipxe script file, default is boot.ipxe.template"
    echo "Example: $0 -n ol1 -d eno2 -p ~/myvms/ol1"
}

check () {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root" >&2
        exit 1
    fi
    local cmd
    for cmd in $CMDS; do
        if ! which $cmd >/dev/null 2>&1; then
            echo "$cmd is missing." >&2
            exit 1
        fi
    done
    local r
    for r in $RPMS; do
        if ! rpm -q $r >/dev/null 2>&1; then
            echo "$r is missing." >&2
            exit 1
        fi
    done
}

echo "Obsoleted. Use new script start.sh"
exit 1

CMDS="gcc git make curl qemu-system-x86_64"
RPMS="glibc-headers"

INVALID_VF_ID="-1"

# ol1 - ol46 in vlan617
MAC_PREFIX="00:18:8b:0b"
# vm1 - vm115 in vlan674
MAC_PREFIX_VLAN="00:18:8b:4c"
TARGET_IP=10.196.242.119
TARGET_IP_VLAN=10.197.0.8

QEMU_IMAGE_BINARIES=http://ca-sysinfra604.us.oracle.com/systest/kvm_images/qemu-img-binaries.tar.gz
USED_VFS=/var/run/vfs

hostname=
pf_dev=
vf_num=1
cpu_num=2
memory=2048 #MB
max_tx_rate=0 #unlimit
dir=
ipxe_script_template=

vlan=1
vlan_id=674

while getopts "n:d:v:p:c:m:r:t:i:h" OPTION; do
    case "$OPTION" in
      n)
        hostname=$OPTARG
        ;;
      d)
        pf_dev=$OPTARG
        ;;
      v)
        vf_num=$OPTARG
        ;;
      c)
        cpu_num=$OPTARG
        ;;
      m)
        memory=$OPTARG
        ;;
      r)
        max_tx_rate=$OPTARG
        ;;
      p)
        dir=$OPTARG
        ;;
      t)
        target_ip=$OPTARG
        ;;
      i)
        ipxe_script_template=$OPTARG
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

if [ -n "$ipxe_script_template" -a ! -f "$ipxe_script_template" ]; then
    echo "$ipxe_script_template not found" >&2
    usage
    exit 1
fi

check

if [ -z "$dir" ]; then
    dir="./$hostname"
fi

# use abs path
dir=$(readlink -f "$dir")
mkdir -p "$dir"

BASE_DIR=$(dirname "$(readlink -f $0)")

if ! ip link show $pf_dev >/dev/null; then
    exit 1
fi

# create VFs and bind it to vfio back
echo "Creating VFs."
$BASE_DIR/create_vf.sh -d $pf_dev

#find an unused vf
vf_id=$(get_vf $pf_dev)
if [ "$vf_id" = "$INVALID_VF_ID" ]; then
    echo "All VFs are in used or VF is not enabled." >&2
    exit 2
fi


vf_pci_addr=$($BASE_DIR/get_vf.sh $pf_dev $vf_id)
echo "Binding $pf_dev VF $vf_id($vf_pci_addr) to vfio-pci."
$BASE_DIR/bind_vfio-pci.sh $vf_pci_addr

# unbind VF from vfio-pci when the script exits and release the VF
trap "release_vf $vf_pci_addr" SIGINT SIGTERM SIGQUIT EXIT

# tagged vlan
if [ $vlan -eq 1 ]; then
    ip link set dev $pf_dev vf $vf_id vlan $vlan_id
    ip link show vlan$vlan_id >/dev/null 2>&1 || \
      ip link add link $pf_dev  name vlan$vlan_id type vlan id $vlan_id
    ip link set vlan$vlan_id up

    # do not set VEPA because the switch doesn't support VEPA
    # set VEPA
    #echo "Set the bridging mode for $pf_dev to vepa"
    #bridge link set dev $pf_dev hwmode vepa

    # mac
    mac=$(get_mac $MAC_PREFIX_VLAN $hostname)
    # vnc_port - host id + 36 as the first 36 ports are used for ol1 - 36
    vnc_port=$((${hostname[@]:2}+36))

    # iscsi target IP
    target_ip=$TARGET_IP_VLAN
# untagged vlan
else
    # reset it to vlan 0
    ip link set dev $pf_dev vf $vf_id vlan 0

    # mac
    mac=$(get_mac $MAC_PREFIX $hostname)
    # vnc port - the host id 1 - 36
    vnc_port=$((${hostname[@]:2}))

    # iscsi target IP
    target_ip=$TARGET_IP
fi

echo "Setting MAC address $mac to $pf_dev VF $vf_id"
ip link set dev $pf_dev vf $vf_id mac $mac spoofchk off

if [ $max_tx_rate -ne 0 ]; then
    echo "Setting $pf_dev VF $vf_id TX max rate to $max_tx_rate"
    ip link set dev $pf_dev vf $vf_id max_tx_rate $max_tx_rate
fi

mkdir -p $dir/write-qemu

#download ovmf files
if [ ! -f "$dir/qemu-img-binaries/OVMF_VARS.fd" -o ! -f "$dir/qemu-img-binaries/OVMF_CODE.fd" ]; then
    echo "Dowlading OVMF ROM files"
    curl $QEMU_IMAGE_BINARIES | tar -xzf - -C $dir \
        qemu-img-binaries/OVMF_CODE.fd qemu-img-binaries/OVMF_VARS.fd
fi

# rebuild ipxe rom files with customized ipxe script
[ -z "$ipxe_script_template" ] && ipxe_script_template=$BASE_DIR/boot.ipxe.template
ipxe_file=$dir/boot.ipxe
# do not build rom files if they are already built
#if [ ! -f "$dir/ipxe/bin-x86_64-efi/snp.efirom" ]; then
if [ ! -f "$ipxe_file" ]; then
    /bin/cp -f "$ipxe_script_template" $ipxe_file
    sed -i "s/{{HOSTNAME}}/$hostname/g" $ipxe_file
    sed -i "s/{{TARGET_IP}}/$target_ip/g" $ipxe_file
    echo "Building customized iPXE ROM files with embedded script $ipxe_file."
    echo "Check build log at $dir/ipxe_build.log"
    $BASE_DIR/build_ipxe_romfiles.sh $dir $BASE_DIR/vendor_devices $ipxe_file
fi

start_instance $dir $cpu_num $memory $vf_pci_addr $vnc_port
