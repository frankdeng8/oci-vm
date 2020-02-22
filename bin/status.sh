#!/bin/bash
set -e

usage () {
    echo "Usage:"
    echo "$0 -a [vm Hostname] -P [vm working dir]"
    echo "$0 -P [vm working dir]"
    echo "Options:"
    echo "  -n [vm hostname], available hostname:"
    echo "     ol1 - ol36 in vlan 617"
    echo "     vm1 - vm115 in tagged vlan $vlan_id"
    echo "  -P [VM working directory], default is ./<hostname>"
}

hostname=
dir=

while getopts "a:P:h" OPTION; do
    case "$OPTION" in
      a)
        hostname=$OPTARG
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

if [ -n "$hostname" ]; then
    if [[ "$hostname" == ol* ]]; then
        vlan=0
    elif [[ "$hostname" == vm* ]]; then
        vlan=1
    else
        echo "Wrong hostname $hostname" >&2
        usage
        exit 1
    fi
fi

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
# . $BASE_DIR/common.sh

# vm work dir
if [ -z "$dir" ]; then
    dir="./$hostname"
fi
# use abs path for vm work dir
dir=$(readlink -f "$dir")

if [ ! -d "$dir" ]; then
    echo "$dir not found" >&2
    exit 1
fi
$BASE_DIR/hmp.sh "$dir" "info status"
$BASE_DIR/qmp.sh "$dir" "query-status"
