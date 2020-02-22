#!/bin/bash
set -e

BASE_DIR=$(dirname "$(readlink -f $0)")

usage () {
    echo "Usage:"
    echo "$0 -P [vm working dir]"
    echo "Options:"
    echo "  -P [VM working directory]"
}

dir=

while getopts "P:h" OPTION; do
    case "$OPTION" in
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

# use abs path for vm work dir
dir=$(readlink -f "$dir")

$BASE_DIR/hmp.sh "$dir" "system_reset"
