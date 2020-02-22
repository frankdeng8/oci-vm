#!/bin/bash

set -e
set -x

usage () {
    echo "Usage:"
    echo "  ${0##*/} -n [hostname] -o [OS name] -i [image location]"
    echo "  Options:"
    echo "    -n [hostname], Available hostname: ol1-ol36, vm1-vm100"
    echo "    -o [OS name], OL6/OL7/OL8/Ubuntu14/Ubuntu16/Ubuntu18"
    echo "    -i [Image], e.g /OCI_images/Oracle-Linux-7.7-2019.10.16-773/output.QCOW2"
    echo "    -s, enable systemd debug with 'systemd.log_level=debug'"
    echo "    -m, use default cloud-init config and metadata service IP 169.254.169.254'"
    echo "    -p for pv boot only meaning leaving 169.254.0.2 as iscsi target."
    echo "Examples:"
    echo "  To create a LUN from OL7"
    echo "  # create-lun -n vm1 -o OL7 -i /OCI_images/OL7.4-20170926"
    echo "  To create a LUN from Ubuntu16 image"
    echo "  # create-lun -n vm1 -o Ubuntu16 -i /OCI_images/Ubuntu16/20171006/livecd.ubuntu-cpc.oracle_bare_metal.img"
    echo "  To create a lun from OL7 and boot it in PV mode only, please add '-p' option"
    echo "  # create-lun -n vm1 -o OL7 -i /OCI_images/OL7.4-20170926 -p"
    echo
}

configure_target () {
    if ! targetcli /iscsi/ ls $TARGET_IQN; then
        targetcli /iscsi/ create $TARGET_IQN
        targetcli saveconfig
    fi
}

generate_lun_id () {
    local used_ids=$(targetcli /iscsi/iqn.2015-02.oracle.boot:uefi/tpg1/luns ls 2>/dev/null | \
        awk '{print $2'}  | sed '1d' | sed 's/lun//g' | sort -n)
    local i=1
    while echo "$used_ids" | grep -q "^$i$"; do
        i=$(($i+1))
    done
    if [ "$i" -le 255 ]; then
        echo $i
    fi
}

get_boot_lun_id () {
    local hostname=$!
    targetcli /iscsi/$TARGET_IQN/tpg1/luns ls 2>/dev/null | \
        grep "/$hostname/image.raw" |  awk '{print $2}' | sed 's/lun//'
}

get_data_lun_id () {
    local hostname=$!
    targetcli /iscsi/$TARGET_IQN/tpg1/luns ls 2>/dev/null | \
        grep "/$hostname/data.raw" |  awk '{print $2}' | sed 's/lun//'
}
get_data_lun_ids () {
    local hostname=$!
    targetcli /iscsi/$TARGET_IQN/tpg1/luns ls 2>/dev/null | \
        grep "/$hostname/data*.raw" |  awk '{print $2}' | sed 's/lun//'
}

create_lun () {
    local hostname=$1
    local image=$2
    local initiator_iqn=$IQN_PREFIX:$hostname
    local filename=$hostname

    targetcli /backstores/fileio create name=$filename file_or_dev=$image write_back=false

    local lun_id=$(generate_lun_id)
    if [ -n "$lun_id" ]; then
        targetcli /iscsi/$TARGET_IQN/tpg1/luns create /backstores/fileio/$filename $lun_id false
        targetcli /iscsi/$TARGET_IQN/tpg1/acls create $initiator_iqn false
        targetcli /iscsi/$TARGET_IQN/tpg1/acls/$initiator_iqn create 0 $lun_id
        targetcli saveconfig
    else
        echo "Could not create LUN - full." >&2
        return 1
    fi
}

delete_lun () {
    local hostname=$1
    local image=$2
    local initiator_iqn=$IQN_PREFIX:$hostname
    local boot_filename=$hostname
    local filename=
    local boot_lun_id=$(get_boot_lun_id $hostname)
    local data_lun_ids=$(get_data_lun_ids $hostname)
    # delete acl

    if targetcli /iscsi/$TARGET_IQN/tpg1/acls/ ls $initiator_iqn; then
        targetcli /iscsi/$TARGET_IQN/tpg1/acls/ delete $initiator_iqn
    fi

    # delete boot lun and data luns
    local lun_id=
    for lun_id in $boot_lun_id $data_lun_ids; do
        # delete lun
        if [ -n "$lun_id" ]; then
            if targetcli /iscsi/$TARGET_IQN/tpg1/luns ls lun$lun_id; then
                targetcli /iscsi/$TARGET_IQN/tpg1/luns delete lun$lun_id
            fi
        fi
    done
    local data_filenames=
    local c=1
    while [ $c -lt 20 ]; do data_filenames="$data_filenames ${hostname}_$c"; c=$(($c+1)); done
    for filename in $boot_filename $data_filenames; do
        if [ -n "$filename" ]; then
            if targetcli /backstores/fileio/ ls $filename; then
                targetcli /backstores/fileio delete name=$filename
            else
                break
            fi
        fi
    done
    targetcli saveconfig
}

cleanup_mnts () {
    #local image=$1
    local mp=$1
    mount |grep -q "$mp/dev" && \
        umount $mp/dev
    # mount |grep -q "$mp/proc" && \
    #     umount $mp/proc
    # mount |grep -q "$mp/sys" && \
    #     umount $mp/sys
    # mount |grep -q "$mp/boot/efi" && \
    #     umount $mp/boot/efi/

    #$BASE_DIR/mntimg -l | grep -q $image && \
    #    $BASE_DIR/mntimg -u $image
    if mount | grep -q "$mp"; then
       guestunmount --no-retry -q "$mp"
    fi
    sync;sync;sync
}

TGT_DIR=/home/tgt
IQN_PREFIX='iqn.2015-02.oracle.boot'
TARGET_IQN="$IQN_PREFIX:uefi"

hostname=
os=

# pv - 0 - modify netroo in grub config
# pv -1 - do not modify netroot
pv=0

# nocloud - 0, do not add nocloud datasource to cloudt config, not custom cloud config
# nocloud - 1, use nocloud datasource for custom cloud config
nocloud=1

# systemd_debug - 1, add systemd.log_level=debug to grub config
systemd_debug=0

while getopts "n:o:i:hpms" OPTION; do
    case "$OPTION" in
      n)
        hostname=$OPTARG
        ;;
      o)
        os=$OPTARG
        ;;
      i)
        oci_image=$OPTARG
        ;;
      p)
        pv=1
        ;;
      m)
        nocloud=0
        ;;
      s)
        systemd_debug=1
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

if [ "$os" != "OL8" -a "$os" != OL7 -a "$os" != OL6 -a "$os" != Ubuntu16 -a "$os" != Ubuntu14 ]; then
    echo "OS $os not found" >&2
    usage
    exit 1
fi

BASE_DIR=$(dirname "$(readlink -f $0)")

dir="$TGT_DIR/$hostname"

#trap "" SIGINT SIGTERM SIGQUIT EXIT
if [ ! -f "$oci_image" ]; then
    echo "OCI image $oci_image not found" >&2
    exit 1
fi

mkdir -p "$dir"

image=$dir/image.raw
# configure iSCSI target
configure_target
# delete lun on iSCSI target
delete_lun $hostname $image

# create new image
# conver qcow format to raw iamge

/bin/rm -f "$image"
if [ ! -f "$image" ]; then
    # this should be OL image
    if file "$oci_image" | grep -q QCOW; then
        qemu-img convert -O raw "$oci_image" "$image"
    else
        # this should be Ubuntu image
        /bin/cp -f --sparse=always "$oci_image" "$image"
    fi
    sync
fi

# expand size for Ubuntu image
# resize ext4 root fs for Ubuntu image
if [ "$os" = Ubuntu16 -o "$os" = Ubuntu14 -o "$os" = "Ubuntu18" ]; then
    # increase Ubuntu images size, Ubuntu16 only has 2GB, and Ubunt14 has 8GB
    qemu-img resize -f raw "$image" +50G
    growpart "$image" 1
    guestfish -i -a $image resize2fs /dev/sda1
fi

# OL8 specific fix for fsck vfat
#if [ "$os" = OL8 ]; then
#    guestfish -a "$image" -i fsck vfat /dev/sda1
#    guestfish -a "$image" -i rm /boot/efi/FSCK0000.REC || :
#fi

image_mnt=$dir/image_mnt
mkdir -p $image_mnt
/bin/rm -rf $image_mnt/*

# mount the image
#$BASE_DIR/mntimg -r $image $image_mnt
guestmount -i -a "$image" "$image_mnt"

#trap "cleanup_mnts $image" SIGINT SIGTERM SIGQUIT EXIT
trap "cleanup_mnts '$image_mnt'" SIGINT SIGTERM SIGQUIT EXIT

# resize ext4 root fs for Ubuntu image
if [ "$os" = Ubuntu16 -o "$os" = Ubuntu14 -o "$os" = "Ubuntu18" ]; then
    mount --bind /dev/  $image_mnt/dev
    #lp_dev=$($BASE_DIR/mntimg -l "$image"  |grep "$image_mnt$" |awk -F: '{print $2}' | awk '{print $1}')
    #resize2fs $lp_dev
fi
# hack the os content
$BASE_DIR/hack_os.sh $image_mnt $hostname $os $pv $nocloud $systemd_debug

# add oci image info to the image
echo "$oci_image" > $image_mnt/root/IMG_VER
echo "Instance created from image $oci_image" >> $image_mnt/etc/motd
echo "" >> $image_mnt/etc/motd
sync;sync;sync

#$BASE_DIR/mntimg -u $image
if [ "$os" = Ubuntu16 -o "$os" = Ubuntu14 -o "$os" = "Ubuntu18" ]; then
    mount |grep -q "$image_mnt/dev" && \
        umount $image_mnt/dev
fi
guestunmount -v "$image_mnt"
sync;sync;sync

# create lun on iSCSI target
if ! create_lun $hostname $image; then
    exit 1
fi

echo "$hostname $os $oci_image pv=$pv" nocloud=$nocloud> "$dir/info"

targetcli / ls

echo "Created $hostname with $os image $oci_image ."
