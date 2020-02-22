#!/bin/bash
# build ipxe rom files
set -e
#set -x

usage () {
    echo "Usage:"
    echo "$0 [working dir] [out dir] [vendor devices file] [embeded ipxe script]"
    echo "Example:"
    echo "$0 ./ipx_build ~/myvm/ol1/read-qemu ./vendor_devices ./myscript.ipxe"
}

dir=$1
out_dir=$2
vendor_devices_file=$3
ipxe_script=$4

# the original oci ipxe git is
# ssh://git@bitbucket.oci.oraclecorp.com:7999/cccp/ipxe.git
# Konrad has a clone git://char.us.oracle.com/ipxe.git but it's not up to date.
# ca-git has part of oci ipxe git.
# so we need to use oci repo, however oci repo only offers ssh clone, which requires
# oci account and a uploaded ssh public key.
# I clone the repo to ca-sysinfra604:/systest/ipxe/ipxe, make a tarball oci_ipxe_src.tar.gz

# The previous ipxe repos we used:
# ipxe_git=git://ca-git.us.oracle.com/ipxe.git
# ipxe_branch=origin/oci/20171112-Stable

# ipxe_git=git://char.us.oracle.com/ipxe.git
# ipxe_branch=master

ipxe_src_tarball=http://ca-sysinfra604.us.oracle.com/systest/public/oci_src/ipxe.tar.gz

if [ ! -d "$dir" ]; then
    usage
    exit 1
fi

if [ ! -f "$vendor_devices_file" ]; then
    usage
    exit 1
fi
vendor_devices_file=$(readlink -f "$vendor_devices_file")

if [ ! -f "$ipxe_script" ]; then
    usage
    exit 1
fi
ipxe_script=$(readlink -f "$ipxe_script")
out_dir=$(readlink -f "$out_dir")

if ! which git >/dev/null 2>&1; then
    echo "git is missing." >&2
    exit 1
fi
if ! which make >/dev/null 2>&1; then
    echo "make is missing." >&2
    exit 1
fi
if ! which gcc >/dev/null 2>&1; then
    echo "gcc is missing." >&2
    exit 1
fi

mkdir -p $dir

cd $dir

/bin/rm -rf ipxe
# /bin/rm -f ipxe_build.log

# we don't clone ipxe git repo as the available git repo is old
# git clone $ipxe_git
# cd ipxe
# git checkout -b build --track $ipxe_branch
tarball=${ipxe_src_tarball##*/}
/bin/rm -f $tarball

echo "Dowloading $ipxe_src_tarball"
if ! wget -q $ipxe_src_tarball; then
    echo "Failed to download $ipxe_src_tarball" >&2
    exit 2
fi
if ! tar -xf $tarball; then
    echo "Failed to extrac $tarball" >&2
    exit 3
fi

cd ipxe
cd src

for vendor_device in $(cat $vendor_devices_file); do
    echo "Building $vendor_device.efirom with $ipxe_script"
    make bin-x86_64-efi/$vendor_device.efirom EMBED=$ipxe_script 2>&1 >> ../../ipxe_build.log
    #make bin-x86_64-efi/${vendor_device}-debug.efirom \
    #    EMBED=$ipxe_script DEBUG="efi_block:3, scsi:3" 2>&1 | tee -a ../../ipxe_build.log
done

#cd ../..
#mkdir -p qemu-img-binaries
#/bin/rm -f qemu-img-binaries/*.efirom
#cp -a -f ipxe/src/bin-x86_64-efi/*.efirom qemu-img-binaries

mkdir -p $out_dir
/bin/rm -f $out_dir/*.efirom
cp -a -f bin-x86_64-efi/*.efirom $out_dir
