#!/bin/bash

# $1 - vm anme, e.g vm1
# $2 - vnic #
#     1 - primary vnic only
#     2 - primary vnic and 1 2nd vnics
#     7 - primary vnic and 6 2nd vnics
# IMDS, two dirs
#  openstack
#  opc
#
# the dir name format:
#  <openstack|opc>-<vm name>[-<vnic #>]
# no nic info in openstack IMDS
# Examples:
#  openstack-vm1
#  opc-vm1-7

usage () {
    echo "Usage: $0 <vm name> <# of nics>" >&2
}

vm=$1
vnic=$2

if [ -z "$vm" ] || [ -z "$vnic" ]; then
    usage
    exit 1
fi

BASE_DIR=$(dirname "$(readlink -f $0)")

IMDS_DIR="/var/www/html/IMDS"
OPENSTACK_DIR="/var/www/html/openstack"
OPC_DIR="/var/www/html/opc"

openstack_dir="$IMDS_DIR/openstack-$vm"
opc_dir="$IMDS_DIR/opc-${vm}-${vnic}"

for d in "$openstack_dir" "$opc_dir"; do
    if [ ! -d  "$d" ]; then
        echo "$d not found." >&2
        usage
        exit 2
    fi
done

echo "Setting IMDS to $openstack_dir and $opc_dir"
rm -f "$OPENSTACK_DIR" "$OPC_DIR" &&
ln -sf "$openstack_dir" "$OPENSTACK_DIR" &&
ln -sf "$opc_dir" "$OPC_DIR"

echo "Please verify:"
echo "IMDS - Openstack:"
curl 169.254.169.254/openstack/latest/meta_data.json
echo "IMDS - OPC:"
curl 169.254.169.254/opc/v1/instance/
curl 169.254.169.254/opc/v1/vnics/
