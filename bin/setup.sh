#!/bin/bash

set -x
# usage:  create_vfs.sh -d 0000:30:00.1 -m ol7 -o attach
usage () {
    echo "Usage:"
    echo "$0 -n 'hostname1 hostname2 ..' -o 'hv'"
    echo "-n hostnames"
    echo "-o op, hv - hypervisor, will install qemu libvirt etc."
}

while getopts "n:o:h" OPTION; do
    case "$OPTION" in
      n)
        hosts=$OPTARG
        ;;
      o)
        op=$OPTARG
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


script=$(mktemp /tmp/setup_XXXX.sh)

cat > $script <<-EOF
#!/bin/bash
set -x
. /root/proxyon
# yum -y update
yum -y install git make subversion vim iperf3 fio gcc nfs-utils lshw hwloc psmisc
cd /root
mkdir -p trunk
cd trunk
svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/tool
svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/hcl_lab
svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/qemu
svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/libvirt
svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/system_test
cd ..
ln -sf trunk/qemu .
ln -sf trunk/hcl_lab/scenario_tester .
ln -sf trunk/tool/spectre_meltdown/simple-checker.sh .
ln -sf trunk/tool/spectre_meltdown .
cat /etc/oracle-release > /etc/motd
EOF

if [ "$op" = hv ]; then

cat >> $script <<-EOF
cat > /etc/yum.repos.d/virt.repo <<REPO
[oraclecloud]
# this repo contains qemu 2.9/2.11, libvirt 3.5/4.0 and seabios etc.
name=OracleCloud
baseurl=http://ca-artifacts.us.oracle.com/auto-build/oraclecloud/ol7/x86_64/
enabled=1
gpgcheck=0
REPO

yum -y install qemu libvirt qemu-img socat

# enable THP
if egrep "^GRUB_CMDLINE_LINUX" /etc/default/grub | grep "transparent_hugepage"; then
    sed -i 's/transparent_hugepage=[a-z]*/transparent_hugepage=always/g' /etc/default/grub
    grub2-mkconfig -o /etc/grub2-efi.cfg
fi
# add iommu
if ! egrep "^GRUB_CMDLINE_LINUX" /etc/default/grub | grep "intel_iommu=on iommu=pt"; then
    sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 intel_iommu=on iommu=pt"/g' /etc/default/grub
    grub2-mkconfig -o /etc/grub2-efi.cfg
fi
echo "This is qemu/libvirt hypervisor." >> /etc/motd
EOF

fi

cat >> $script <<-EOF
hostname
echo "Done"
/bin/rm -f $0
EOF

cat $script

chmod +x $script

for host in $hosts; do
    scp $script root@$host:/tmp
done

for host in $hosts; do
    ssh root@$host "$script" &
done

# wait till all ssh jobs complete
for job in $(jobs -p); do
    wait $job
done

/bin/rm -f $script
