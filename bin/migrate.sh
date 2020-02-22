#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

usage () {
    echo "Usage:"
    echo "$0 -P <vm working dir> -d <dest host>"
    echo "Options:"
    echo "  -P [VM working directory], default is ./<hostname>"
    echo "  -d [Dest host], dest host for live migration"
    echo "Example: $0 -P ~/myvms/ol1 -d 10.0.0.2"
}

hostname=
dest_host=
dir=

while getopts "P:d:h" OPTION; do
    case "$OPTION" in
      P)
        dir=$OPTARG
        ;;
      d)
        dest_host=$OPTARG
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

if [ -z "$dest_host" ]; then
    echo "Dest host not found" >&2
    usage
    exit 1
fi

# use abs path for vm work dir
dir=$(readlink -f "$dir")

if [ -f "$dir/hostname" ]; then
    hostname=$(cat $dir/hostname)
else
    echo "$dir/hostname not found." >&2
    usage
    exit 1
fi

port=$(get_migration_port $hostname)
echo "Migrating VM $hostname to $dest_host"
cmd="migrate uri=tcp:$dest_host:$port"
$BASE_DIR/qmp.sh "$dir" "$cmd"
