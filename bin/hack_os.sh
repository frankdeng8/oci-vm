#!/bin/bash

# Modify oci Linux image to be used in systest lab
set -xe

BASE_DIR=$(dirname "$(readlink -f $0)")

image_root=$1
hostname=$2
os=$3
pv=$4
CLOUD_INIT_NOCLOUD=$5
ENABLE_SYSTEMD_DEBUG=$6

# initiator name will be "iqn.2015-02.oracle.boot:$hostname"
root_password='test4oel'
# hashed_root_password='$6$random_salt$bw8yciFKOxI/RRm3fJQGMcGzHqp7S4Pol0RtsfSZ7YveHAZj6pWtIQThXbTSolm3Q/l7OxLKBVmbkBxKsQwAz0'

#target_ip='169.254.0.2'


if [ ! -d "$image_root" ]; then
    echo "Image root $image_root dos not exist."
    exit 1
fi

if [ -z "$hostname" ]; then
    echo "Hostname is required."
    exit 1
fi

if [ "$os" != OL8 -a "$os" != OL7 -a "$os" != OL6 -a \
  "$os" != Ubuntu16 -a "$os" != Ubuntu14 -a "$os" != Ubuntu18 ]; then
    echo "OS $os is not supported."
    exit 1
fi

if [[ "$hostname" == ol* ]] || [[ "$hostname" == ca-* ]]; then
    target_ip=10.196.242.119
    infra_ip=10.196.240.1
elif [[ "$hostname" == vm* ]]; then
    target_ip=10.197.0.8
    infra_ip=10.197.0.1
else
    echo "Wrong hostname $hostname"
    exit 1
fi

# OL specific modifications
if [ "$os" = OL7 -o "$os" = OL6 -o "$os" = OL8 ]; then

    # OL version will be $VERSION_ID
    . "$image_root/etc/os-release"

    # clean up yum var ociregion
    [ -f "$image_root/etc/yum/vars/ociregion" ] && > "$image_root/etc/yum/vars/ociregion"

    # pv = 0 - iscsi boot
    # pv = 1 - pv boot, so we only modify the target ip for iscsi boot
    # leave 169.254.0.2 as target ip for PV boot.
    if [ "$pv" = 0 ]; then
        # OL6, OL7 add iscsi initiator and update target info in grub
        for grub_cfg in grub.cfg grub.conf; do
            if [ -f "$image_root/boot/efi/EFI/redhat/$grub_cfg" ]; then
                sed -i "s/169.254.0.2/$target_ip/g" $image_root/boot/efi/EFI/redhat/$grub_cfg
                # workaround: add iscsi_initiator parameter to grub
                # rd.iscsi.initiator is supposed to replace iscsi_initiator which is deprecated
                # but OL6 only work with iscsi_initiator parameter
                sed -i "s/boot:uefi/boot:uefi iscsi_initiator=iqn.2015-02.oracle.boot:$hostname/g" \
                    $image_root/boot/efi/EFI/redhat/$grub_cfg
                # enable systemd debug
            fi
        done
        # OL8 specific, kernel params in grubenv, add iscsi initiator, and update target info
        if [ "$os" = "OL8" ]; then
            if [ -f "$image_root/boot/efi/EFI/redhat/grubenv" ]; then
                sed -i "s/169.254.0.2/$target_ip/g" "$image_root/boot/efi/EFI/redhat/grubenv"
                sed -i "s/boot:uefi/boot:uefi rd.iscsi.initiator=iqn.2015-02.oracle.boot:$hostname/g" \
                  "$image_root/boot/efi/EFI/redhat/grubenv"
            fi

        fi
        if [ -f "$image_root/etc/default/grub" ]; then
            sed -i "s/169.254.0.2/$target_ip/g" $image_root/etc/default/grub
            # workaround: add iscsi_initiator parameter to grub
            # rd.iscsi.initiator is supposed to replace iscsi_initiator which is deprecated
            # but OL6 only work with iscsi_initiator parameter
            sed -i "s/boot:uefi/boot:uefi iscsi_initiator=iqn.2015-02.oracle.boot:$hostname/g" \
                $image_root/etc/default/grub
        fi
        # update root device startup to onboot
        # OL6/7
        [ -f "$image_root/etc/rc.d/init.d/iscsi-boot-volume" ] && \
            sed -i "s/169.254.0.2/$target_ip/g" $image_root/etc/rc.d/init.d/iscsi-boot-volume
        # OL8
        [ -f "$image_root/usr/sbin/iscsi-boot-volume" ] && \
            sed -i "s/169.254.0.2/$target_ip/g" $image_root/usr/sbin/iscsi-boot-volume

        # iscsi
        if [ -d "$image_root/var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/169.254.0.2,3260,1" ];then
            if [ "$target_ip" != 169.254.0.2 ]; then
                mv "$image_root/var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/169.254.0.2,3260,1" \
                    "$image_root/var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/$target_ip,3260,1"
                sed -i "s/169.254.0.2/$target_ip/g" \
                    "$image_root/var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/$target_ip,3260,1/default"
                cat "$image_root/var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/$target_ip,3260,1/default"
            fi
        fi
    fi
    # enable systemd debug
    if [ $ENABLE_SYSTEMD_DEBUG = 1 ]; then
        if [ -f $image_root/boot/efi/EFI/redhat/grub.cfg ]; then
            sed -i "s/boot:uefi/boot:uefi systemd.log_level=debug/g" \
                $image_root/boot/efi/EFI/redhat/grub.cfg
        fi
        if [ $image_root/etc/default/grub ]; then
            sed -i "s/boot:uefi/boot:uefi systemd.log_level=debug/g" $image_root/etc/default/grub
        fi
    fi

    # remove dhclient exit hook script
    #[ -f "$image_root/etc/dhcp/exit-hooks.d/dhclient-exit-hook-set-hostname.sh" ] && \
    #    /bin/mv -f "$image_root/etc/dhcp/exit-hooks.d/dhclient-exit-hook-set-hostname.sh" \
    #        "$image_root/etc/dhcp/exit-hooks.d/dhclient-exit-hook-set-hostname.sh.disabled"

    # ntp
    # OL6, 7 ntpd
    #[ -f "$image_root/etc/ntp.conf" ] && \
    #    sed -i "s/169.254.169.254/$infra_ip/g" "$image_root/etc/ntp.conf"
    # OL8 chrony
    #[ -f "$image_root/etc/chrony.conf" ] && \
    #    sed -i "s/169.254.169.254/$infra_ip/g" "$image_root/etc/chrony.conf"

    #dns
    [ "$image_root/etc/resolv.conf" ] && \
        sed -i "s/169.254.169.254/$infra_ip/g" "$image_root/etc/resolv.conf"

    # yum/dnf proxy
    [ -f "$image_root/etc/dnf/dnf.conf" ] && \
        echo "proxy=http://www-proxy.us.oracle.com:80/" >> "$image_root/etc/dnf/dnf.conf"
    [ -f "$image_root/etc/yum.conf" -a ! -h "$image_root/etc/yum.conf" ] && \
        echo "proxy=http://www-proxy.us.oracle.com:80/" >> "$image_root/etc/yum.conf"

    # GPU specific
    #[ -f "$image_root/etc/yum.repos.d/nvidia-cuda.repo" ] && \
    #    echo "proxy=http://www-proxy.us.oracle.com:80/" >> "$image_root/etc/yum.repos.d/nvidia-cuda.repo"

    # hack cloud-init
    # remove Openstack datasource
    #sed -i "s/datasource_list: \['OpenStack'\]/datasource_list: \['None'\]/g" $image_root/etc/cloud/cloud.cfg
    # add ntp cloud-config-module
    sed -i '/timezone/a\ - ntp' $image_root/etc/cloud/cloud.cfg

    if [ $CLOUD_INIT_NOCLOUD -eq 1 ]; then
        # generic: root/opc passwd, ssh login, timezone
        cat > $image_root/etc/cloud/cloud.cfg.d/99_systest.cfg <<EOF
# systest cloud config
datasource_list: ['None']
users:
  - default
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA4umTVJaPBol7hz/CKJZy6yJkpSkESuMoNIwUDyYViQxHRbo72dzpA0JtfLmuM9mIEGnJJ6gS+09z6X1x4HReR0MFElAyb5X2zZM0loUWtK0FMzzbuhmj6loyM1y/3Vn3rYssRRjUOsq6Dwt4AVDHluYWgQl9HG6ydBu7fHZg4BLwEdEoE0d67Ib3yz4i4ww/ihV7EN3bOZH8H3i/pACZ7sGSwT0IfJGbE2APdChMkn9vGzwQuikJfOd1TdyTXpLGDDRNbvWtwxn6LQHzDAgu/ze3SiwQokAjwPZRoSSHvTVvq2BvAtq0oJ9/wjNZbLkuwi1Iw3wN4G2rv7yK3RIH9Q== root@ca-systest
  - name: opc
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA4umTVJaPBol7hz/CKJZy6yJkpSkESuMoNIwUDyYViQxHRbo72dzpA0JtfLmuM9mIEGnJJ6gS+09z6X1x4HReR0MFElAyb5X2zZM0loUWtK0FMzzbuhmj6loyM1y/3Vn3rYssRRjUOsq6Dwt4AVDHluYWgQl9HG6ydBu7fHZg4BLwEdEoE0d67Ib3yz4i4ww/ihV7EN3bOZH8H3i/pACZ7sGSwT0IfJGbE2APdChMkn9vGzwQuikJfOd1TdyTXpLGDDRNbvWtwxn6LQHzDAgu/ze3SiwQokAjwPZRoSSHvTVvq2BvAtq0oJ9/wjNZbLkuwi1Iw3wN4G2rv7yK3RIH9Q== root@ca-systest

chpasswd:
  list: |
    root:$root_password
    opc:$root_password
  expire: False

disable_root: False
ssh_pwauth: True

timezone: America/Los_Angeles

EOF
    fi

    # OL7/8 specific
    if [ "$os" = OL7 -o "$os" = OL8 ]; then
        # might need to disable cloud-init as it takes time to connect to metadata service
        #chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-init.service"
        #chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-config.service"
        #chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-final.service"
        #chroot $image_root /bin/bash -c "/bin/systemctl mask cloud-init.service"
        #chroot $image_root /bin/bash -c "/bin/systemctl mask cloud-config.service"
        #chroot $image_root /bin/bash -c "/bin/systemctl mask cloud-final.service"

        # cloud.cfg: ntp: chrony, disable firewalld
        # ISSUE: OL& cloud-init version 18.2 doesn't have chrony schema
        if [ $CLOUD_INIT_NOCLOUD -eq 1 ]; then
            cat >> $image_root/etc/cloud/cloud.cfg.d/99_systest.cfg <<EOF
ntp:
  enabled: true
  ntp_client: chrony
  config:
    service_name: chronyd
  servers:
    - $infra_ip


runcmd:
#  - [ systemctl, stop, firewalld ]
#  - [ systemctl, disable, firewalld ]
# disable oracle-cloud-agent
  - systemctl is-enabled oracle-cloud-agent.service &>/dev/null && systemctl disable oracle-cloud-agent.service && systemctl stop oracle-cloud-agent.service
  - systemctl is-enabled oracle-cloud-agent-updater.service &>/dev/null && systemctl disable oracle-cloud-agent-updater.service && systemctl stop oracle-cloud-agent-updater.service
  - restorecon -R /var/lib/iscsi/nodes
  - restorecon /etc/iscsi/initiatorname.iscsi
  - test -e /usr/sbin/iscsi-boot-volume && restorecon /usr/sbin/iscsi-boot-volume
  - test -e /etc/rc.d/init.d/iscsi-boot-volume && restorecon /etc/rc.d/init.d/iscsi-boot-volume
  - cd /root && svn co http://ca-svn.us.oracle.com/svn/repos/rhel4/qa-systest/trunk/tool/spectre_meltdown && ln -sf spectre_meltdown/simple-checker.sh .
  - touch /run/ci_runcmd_done

EOF
        fi

        if [ "$os" = OL7 ]; then
            if [ $CLOUD_INIT_NOCLOUD -eq 1 ]; then
                cat >> $image_root/etc/cloud/cloud.cfg.d/99_systest.cfg <<EOF
packages:
  - cpuid
  - msr-tools
  - git
  - subversion
  - iperf3
  - htop
  - iotop
#  - perf
  - fio
  - psmisc
EOF
            fi

        fi

        if [ "$os" = OL8 ]; then
            if [ $CLOUD_INIT_NOCLOUD -eq 1 ]; then
                cat >> $image_root/etc/cloud/cloud.cfg.d/99_systest.cfg <<EOF
packages:
  - git
  - subversion
  - iperf3
  - iotop
#  - perf
  - fio
  - psmisc
EOF
            fi
        fi

        # disable firewalld for testing
        # chroot $image_root /bin/bash -c "/bin/systemctl disable firewalld.service"

        # workaroud for iSCSI login in kdump kernel

        # workaround for OL7.5 and below (updated on 09/2018)
        # remove /etc/iscsi/initiatorname file
        # kdump kernel get initiator name from kernel cmdline and also improperly append by dracut cmd /etc/cmd.d/50iscsi
        # and the initiatorname is obtained from /etc/iscsi/initiatorname.iscsi

        if [ "$VERSION_ID" = 7.4 -o "$VERSION_ID" = 7.5 ]; then
            [ -f $image_root/etc/iscsi/initiatorname.iscsi ] && \
                /bin/mv -f $image_root/etc/iscsi/initiatorname.iscsi $image_root/etc/iscsi/initiatorname.iscsi.removed
        else

        # workaround for OL7.6 and above (since 09/2018)
        # when kdump initrd is generated, it gets initiator name from /etc/iscsi/initiatorname.iscsi
            sed -i "s/InitiatorName=.*/InitiatorName=iqn.2015-02.oracle.boot:$hostname/g" \
                $image_root/etc/iscsi/initiatorname.iscsi
            cat $image_root/etc/iscsi/initiatorname.iscsi
            #chroot $image_root /bin/bash -c "/sbin/restorecon -v /var/lib/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/10.197.0.8,3260,1/default"
            #chroot $image_root /bin/bash -c "/sbin/restorecon -v /etc/iscsi/initiatorname.iscsi"

        fi
        # timezone
        # doesn't work
        # chroot $image_root /bin/bash -c "/bin/timedatectl set-timezone America/Los_Angeles"
        #[ "$os" = OL7 ] && \
        #    chroot $image_root /bin/bash -c "/bin/ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime"
        #[ "$os" = OL8 ] && \
        #       echo -e "\ntimedatectl set-timezone America/Los_Angeles" >> $image_root/root/custom_firstboot.sh

    elif [ "$os" = OL6 ]; then
        # disable firewalld for testing
        #chroot $image_root /bin/bash -c "chkconfig cloud-init off"
        #chroot $image_root /bin/bash -c "/sbin/chkconfig cloud-init off"
        #chroot $image_root /bin/bash -c "/sbin/chkconfig cloud-config off"
        #chroot $image_root /bin/bash -c "/sbin/chkconfig cloud-final off"
        if [ $CLOUD_INIT_NOCLOUD -eq 1 ]; then
            cat >> $image_root/etc/cloud/cloud.cfg.d/99_systest.cfg <<EOF
runcmd:
#  - service iptables stop
  - touch /run/ci_runcmd_done
EOF
        fi
        # OL6 ntpd
        [ -f "$image_root/etc/ntp.conf" ] && \
            sed -i "s/169.254.169.254/$infra_ip/g" "$image_root/etc/ntp.conf"

        # workaroud for iSCSI login in kdump kernel
        # when kdump initrd is generated, it gets initiator name from /etc/iscsi/initiatorname.iscsi
        sed -i "s/InitiatorName=.*/InitiatorName=iqn.2015-02.oracle.boot:$hostname/g" \
            $image_root/etc/iscsi/initiatorname.iscsi
        cat $image_root/etc/iscsi/initiatorname.iscsi

        # timezone
        # chroot $image_root /bin/bash -c "/bin/ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime"
        # disable oracle-cloud-agent
        mv -f $image_root/etc/init/oracle-cloud-agent.conf $image_root/etc/init/oracle-cloud-agent.conf.bak
        mv -f $image_root/etc/init/oracle-cloud-agent-updater.conf $image_root/etc/init/oracle-cloud-agent-updater.conf.bak
    fi

    # tag autorelabel, os will reboot after firstboot, root password change won't take effect without this
    # touch $image_root/.autorelabel
    #chroot $image_root /bin/bash -c "fixfiles -F relabel"

    # no need to update initrd for OL for now
    if false; then
    #if true; then
        initrd_dir=$image_root/../initrd
        for initrd in $image_root/boot/initramfs-*x86_64.img; do
            echo $initrd
            rm -rf $initrd_dir
            mkdir -p $initrd_dir
            cd $initrd_dir
            /usr/lib/dracut/skipcpio $initrd | zcat | cpio -idv
            # nothing to do here yet
            find . -print | cpio -o -H newc | xz --format=lzma > $image_root/../new-initrd.img
            cd -
            cp -a -f $image_root/../new-initrd.img $initrd
            #/bin/rm -f $image_root/../new-initrd.img
            #/bin/rm -rf $initrd_dir
        done
    fi

# Ubuntu specific modificaitons
elif [ "$os" = Ubuntu16 -o "$os" = Ubuntu14 -o "$os" = Ubuntu18 ]; then
    # network
    cat >> $image_root/etc/network/interfaces <<-EOF
# primary interface
auto ens3
iface ens3 inet dhcp
EOF
    cat $image_root/etc/network/interfaces
    cat >> $image_root/etc/network/interfaces.d/50-cloud-init.cfg <<-EOF
# auto ens3
iface ens3 inet dhcp
EOF
    cat $image_root/etc/network/interfaces.d/50-cloud-init.cfg
    #iscsi
    if [ -d "$image_root/etc/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/169.254.0.2,3260" ]; then
        if [ "$target_ip" != 169.254.0.2 ]; then
            mv "$image_root/etc/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/169.254.0.2,3260" \
               "$image_root/etc/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/$target_ip,3260"
            sed -i 's/169.254.0.2/$target_ip/g' \
                "$image_root/etc/iscsi/nodes/iqn.2015-02.oracle.boot:uefi/$target_ip,3260/default"
        #cat "$image_root/etc/iscsi/nodes/iqn.2015-02.oracle.boot\:uefi/$target_ip\,3260/default"
        fi
    fi
    # generate ssh host keys
    chroot $image_root /bin/bash -c "ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa"
    chroot $image_root /bin/bash -c "ssh-keygen -f /etc/ssh/ssh_host_dsa_key -N '' -t dsa"
    chroot $image_root /bin/bash -c "ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -N '' -t ecdsa"

    # disable cloud-init
    if [ "$os" = Ubuntu16 ]; then
        chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-init.service"
        chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-config.service"
        chroot $image_root /bin/bash -c "/bin/systemctl disable cloud-final.service"
    fi
    # timezone
    chroot $image_root /bin/bash -c "/bin/ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime"

    # update initrd
    initrd_dir=$image_root/../initrd
    for initrd in $image_root/boot/initrd.img-*; do
        echo $initrd
        rm -rf $initrd_dir
        mkdir -p $initrd_dir
        cd $initrd_dir
        gzip -dc $initrd | cpio -id
        sed -i "s/169.254.0.2/$target_ip/g" etc/iscsi.initramfs
        cat etc/iscsi.initramfs
        sed -i "s/InitiatorName=iqn.2015-02.oracle.boot:uefi/InitiatorName=iqn.2015-02.oracle.boot:$hostname/g" \
            etc/initiatorname.iscsi
        cat etc/initiatorname.iscsi
        find . | cpio  -o -H newc | gzip -9 > $image_root/../new-initrd.img
        cd -
        /bin/cp -a -f $image_root/../new-initrd.img $initrd
        #/bin/rm -f $image_root/../new-initrd.img
        #/bin/rm -rf $initrd_dir
    done
fi

# Common modifications for all Linux OS

# timezone already set above
#chroot $image_root /bin/bash -c "/bin/ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime"

# add systest ssh key pair
chroot $image_root /bin/bash -c "/bin/mkdir --mode=700 -p /root/.ssh"
chroot $image_root /bin/bash -c "wget http://ca-sysinfra604.us.oracle.com/systest/public/id_rsa_systest -O /root/.ssh/id_rsa"
chroot $image_root /bin/bash -c "/bin/chmod 600 /root/.ssh/id_rsa"
chroot $image_root /bin/bash -c "wget http://ca-sysinfra604.us.oracle.com/systest/public/id_rsa_systest.pub -O /root/.ssh/id_rsa.pub"
chroot $image_root /bin/bash -c "/bin/chmod 644 /root/.ssh/id_rsa.pub"
#chroot $image_root /bin/bash -c "/bin/cat /root/.ssh/id_rsa.pub > /root/.ssh/authorized_keys"
#chroot $image_root /bin/bash -c "/bin/chmod 600 /root/.ssh/authorized_keys"
chroot $image_root /bin/bash -c "/bin/cat > /root/.ssh/config <<_FILE_
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
LogLevel QUIET
_FILE_"

# add proxyon and proxyoff
chroot $image_root /bin/bash -c '/bin/cat > /root/proxyon << _FILE_
#!/bin/bash
# source this file to turn on proxy
proxy=http://www-proxy.us.oracle.com:80/
export http_proxy=\$proxy
export https_proxy=\$proxy
export ftp_proxy=\$proxy
export HTTPS_PROXY=\$proxy
export HTTP_PROXY=\$proxy
export FTP_PROXY=\$proxy
export no_proxy="localhost,127.0.0.1,.us.oracle.com,.cn.oracle.com,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
export NO_PROXY=\$no_proxy
_FILE_'
chroot $image_root /bin/bash -c '/bin/cat > /root/proxyoff << _FILE_
# source this file to turn off proxy
unset http_proxy
unset https_proxy
unset ftp_proxy
unset HTTPS_PROXY
unset HTTP_PROXY
unset FTP_PROXY
_FILE_'

# add some alias
# alias yum='. ~/proxyon; yum'
chroot $image_root /bin/bash -c "/bin/cat >> /root/.bashrc <<_FILE_
alias vi='vim'
alias reboot='sync; reboot'
_FILE_"

# add a script to clean up ifcfg files
chroot $image_root /bin/bash -c "/bin/cat >> /root/c.sh <<_FILE_
#!/bin/bash
cd /etc/sysconfig/network-scripts/
/bin/rm -f ifcfg-ens*
/bin/rm -f ifcfg-eth*
sync
_FILE_"
chroot $image_root /bin/bash -c "/bin/chmod +x /root/c.sh"

# add .vimrc for root
tmp_file=$(mktemp /tmp/tmp_XXXX)
cat > $tmp_file <<'_FILE_'
" enable syntax highlighting
syntax on
" Highlight redundant whitespaces and tabs.
highlight RedundantSpaces ctermbg=red guibg=red
match RedundantSpaces /\s\+$\| \+\ze\t\|\t/
" use 4 spaces instead of tabs
set tabstop=4
set shiftwidth=4
set expandtab
set softtabstop=4
" always show ^M in DOS files
set fileformats=unix
_FILE_
/bin/cp -a $tmp_file $image_root/root/.vimrc
/bin/rm -f $tmp_file

# add some test scripts
/bin/cp -a $BASE_DIR/crash.sh $image_root/usr/local/sbin

# change root password
# chroot $image_root /bin/bash -c "echo root:$root_password| chpasswd"

