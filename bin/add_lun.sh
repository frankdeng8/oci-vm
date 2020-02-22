#!/bin/bash

set -e
set -x

usage () {
    echo "Usage:"
    echo "  ${0##*/} -n [hostname] -s [size in GB] -c [# of LUNs]"
    echo "  Example: ${0##*/} -n ol1 -s 300 -c 2"
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

create_data_lun () {
    local hostname=$1
    local id=$2
    local image=$3
    local initiator_iqn=$IQN_PREFIX:$hostname
    local filename=${hostname}_$id

    targetcli /backstores/fileio create name=$filename file_or_dev=$image
    local lun_id=$(generate_lun_id)
    if [ -n "$lun_id" ]; then
        targetcli /iscsi/$TARGET_IQN/tpg1/luns create /backstores/fileio/$filename $lun_id false
        #acl should already been created
        targetcli /iscsi/$TARGET_IQN/tpg1/acls/$initiator_iqn create $id $lun_id
        targetcli saveconfig
    else
        echo "Could not create LUN - full." >&2
        return 1
    fi
}

delete_data_lun () {
    local hostname=$1
    #local image=$2
    local initiator_iqn=$IQN_PREFIX:$hostname
    local filename=
    local lun_ids=$(get_data_lun_ids $hostname)

    # delete and data luns
    local lun_id=
    for lun_id in $data_lun_ids; do
        if [ -n "$lun_id" ]; then
            if targetcli /iscsi/$TARGET_IQN/tpg1/luns ls lun$lun_id; then
                targetcli /iscsi/$TARGET_IQN/tpg1/luns delete lun$lun_id
            fi
        fi
    done

    local data_filenames=
    local c=1
    while [ $c -lt 20 ]; do data_filenames="$data_filenames ${hostname}_$c"; c=$(($c+1)); done
    for filename in $data_filenames; do
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

TGT_DIR=/home/tgt

IQN_PREFIX='iqn.2015-02.oracle.boot'
TARGET_IQN="$IQN_PREFIX:uefi"

hostname=
count=1
size=10
force=0

while getopts "n:s:c:hf" OPTION; do
    case "$OPTION" in
      n)
        hostname=$OPTARG
        ;;
      s)
        size=$OPTARG
        ;;
      c)
        count=$OPTARG
        ;;
      f)
        force=1
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

BASE_DIR=$(dirname "$(readlink -f $0)")

dir="$TGT_DIR/$hostname"
if [ ! -d "$dir" ]; then
    echo "$dir does not exist" >&2
    usage
    exit 1
fi

#trap "" SIGINT SIGTERM SIGQUIT EXIT

delete_data_lun $hostname
c=1
while [ $c -le $count ]; do
    image=$dir/data$c.raw
    qemu-img create -f raw $image ${size}G
    # create lun on iSCSI target
    if ! create_data_lun $hostname $c $image; then
        exit 1
    fi
    echo "$hostname $image" >> "$dir/info"
    echo "Created $hostname with ${size}G data image $image."
    c=$(($c+1))
done

targetcli / ls

