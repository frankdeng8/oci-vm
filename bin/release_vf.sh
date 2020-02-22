#!/bin/bash
set -e -x
usage () {
    echo "Usage:"
    echo "$0 [vf pci addr] or 'all'"
}

if [ -z "$1" ]; then
    usage
    exit 1
fi

BASE_DIR=$(dirname "$(readlink -f $0)")
# source lib
. $BASE_DIR/common.sh

if [ "$1" = all ]; then
    vf_pci_addrs=$(awk '{print $4}' "$RESERVED_VFS")
    for vf_pci_addr in $vf_pci_addrs; do
        release_vf $vf_pci_addr
    done
else
    release_vf $1
fi
