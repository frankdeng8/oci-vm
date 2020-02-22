#!/bin/bash

##############################################################
# QMP/HMP related functions

#$1 vm working dir
#$2 specified info
get_info() {
    local dir=$1
    local cmd=
    local i=
    local all_info="status pci network block"
    shift
    if [ -n "$*" ]; then
        all_info=$*
    fi
    for i in $all_info; do
        cmd="info $i"
        $BASE_DIR/hmp.sh "$dir" "$cmd"
    done
}

###############################################################
# get the host hostname in tagged vlan
# $1 - vlan id
get_host_vlan_ip() {
    local vlan_id=$1
    local s_hostname=$(hostname -s)
    local s_hostname_vlan=
    if [ "${s_hostname: -1}" = p ]; then
        s_hostname_vlan="${s_hostname}-v$vlan_id"
    else
        s_hostname_vlan="${s_hostname}p-v$vlan_id"
    fi
    getent hosts $s_hostname_vlan | awk '{print $1}'
}

###############################################################
# get vm uuid by vm hostname
# first 36 bits of hostname sha256sum
# format: 8-4-4-4-12
# example: f1697ad5-296b-4754-9176-aa361550d145
# $1 vm hostname
get_uuid () {
    local hostname=$1
    echo $hostname | sha256sum | cut -c 1-36 | sed -e 's/./-/9' -e 's/./-/14' -e 's/./-/19' -e 's/./-/24'
}
###############################################################
# Is VM in tagged vlan?
# vm hostnames vm1 - vm115 should be in tagged vlan
# $1 vm hostname
# return: 0, 1-tagged vlan
in_vlan() {
    local hostname=$1
    local vlan=
    if [[ "$hostname" == ol* ]]; then
        vlan=0
    elif [[ "$hostname" == vm* ]]; then
        vlan=1
    fi
    echo $vlan
}
###############################################################
# get vm vnc listen port
# ol1 - ol35: 5901 - 5935
# vm1 - vmXX: 5901+36 - 5936+XX
# $1 vm hostname
get_vnc_port() {
    local hostname=$1
    local vlan=
    local port=
    vlan=$(in_vlan $hostname)
    if [ "$vlan" -eq 1 ]; then
        port=$((${hostname[@]:2}+36))
    else
        port=$((${hostname[@]:2}))
    fi
    echo $port
}
###############################################################
# get vm migration listen port
# ol1 - ol35: 5001 - 5035
# vm1 - vmXX: 5036 - 5036+XX
# $1 vm hostname
get_migration_port() {
    local hostname=$1
    local vlan=
    local port=
    vlan=$(in_vlan $hostname)
    if [ "$vlan" -eq 1 ]; then
        port=$((${hostname[@]:2}+36+5000))
    else
        port=$((${hostname[@]:2}+5000))
    fi
    echo $port
}
###############################################################
# get iSCSI target IP for iscsi boot
# $1 vm hostname
get_target_ip() {
    local hostname=$1
    local vlan=
    local target_ip=
    vlan=$(in_vlan $hostname)
    if [ "$vlan" -eq 1 ]; then
        target_ip=$TARGET_IP_VLAN
    else
        target_ip=$TARGET_IP
    fi
    echo $target_ip
}

################################################################
# get vf efi rom file name
# $1 vm working dir
# $2 ipxe boot volume: iscsi, pv, or customized
# $3 vf pci addr or 'virtio'
# return: efi rom file name
get_efirom_file () {
    local dir=$1
    local boot=$2
    local rom_name=
    if [ "$3" = virtio ]; then
        rom_name=1af41000
    else
        local pcidev=$3
        local vendor=$(cat /sys/bus/pci/devices/$pcidev/vendor)
        local device=$(cat /sys/bus/pci/devices/$pcidev/device)
        rom_name=${vendor##0x}${device##0x}
    fi
    # intel, virtio
    if [ -f "$dir/read-qemu/$boot/$rom_name.efirom" ]; then
        echo "$dir/read-qemu/$boot/$rom_name.efirom"
        #echo $rom_name.efirom
    # broadcom
    else
        #echo snp.efirom
        echo "$dir/read-qemu/$boot/snp.efirom"
    fi
}

#############################################################
# table vf: hostname pf_dev vf_id vf_pci_addr
# talbe macvtap hostname pf_dev macvtap_dev
init_db() {
    if [ ! -d "$DB_DIR" ]; then
        mkdir -p "$DB_DIR"
    fi
    if [ ! -f "$DB" ]; then
        local vf_table="CREATE TABLE vf(hostname varchar(20), nic_id int, pf_dev varchar(20), vf_id int, vf_pci_addr varchar(20));"
        local macvtap_table="CREATE TABLE macvtap(hostname varchar(20), nic_id int, pf_dev varchar(20), macvtap_dev varchar(20));"
        sqlite3 $DB "$vf_table"
        sqlite3 $DB "$macvtap_table"
        sqlite3 $DB "savepoint init"
    else
        # might need to re-create schema to add nic_id
        if ! sqlite3 -cmd ".timeout 10000" $DB ".schema" | grep -q nic_id; then
            /bin/rm -f $DB
            init_db
        fi
    fi
}

#############################################################
# vf functions:
# get_vf() - get existing vf id for a vm
# find_vf() - get a new vf id
# reserve_vf(), reserve a vf for a vm
# release_vf(), release the vf for a vm from reserve vf list
# set_vf(), create vlan if required, initialize the vf to be ready for a vm use
# unset_vf(), reset the vf to unused state for a vm
# get_vf_pci_addr(), get vf pci addr
# get_max_vf(), get vf max num of a pf
# ---------------------------------------------------

# get_vf() - get existing vf id for a vm
# $1 vm hostname
# $2 pf dev
# $3 nic_id, default 0
# return: vf id
get_vf() {
    local hostname=$1
    local pf_dev=$2
    local nic_id=0
    # TODO:handle multiple vfs
    if [ -n "$3" ]; then
        nic_id=$3
    fi
    init_db
    #sqlite3 -cmd ".timeout 10000" $DB "SELECT vf_id FROM vf WHERE hostname='$hostname' and pf_dev='$pf_dev' and nic_id='$nic_id'"
    local vf_id=$(sqlite3 -cmd ".timeout 10000" $DB "SELECT vf_id FROM vf WHERE hostname='$hostname' and nic_id='$nic_id'")
    # verify the vf_pci_addr is correct
    if [ -n "$vf_id" ]; then
        local vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
        local vf_pci_addr_db=$(sqlite3 -cmd ".timeout 10000" $DB "SELECT vf_pci_addr FROM vf WHERE hostname='$hostname' and nic_id='$nic_id'")
        if [ "$vf_pci_addr" != "$vf_pci_addr_db" ]; then
            sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM vf WHERE hostname='$hostname' and nic_id='$nic_id';"
        else
            echo $vf_id
        fi
    fi

    #if [ -f "$RESERVED_VFS" ]; then
    #    local s=$(grep "$hostname " "$RESERVED_VFS")
    #    #local pf_dev=$(echo $s | awk '{print $2}')
    #    echo $s | awk '{print $3}'
    #fi
}
# find_vf() - get a new vf id
# $1: pf dev
# return: vf id
find_vf () {
    local pf_dev=$1
    local vf_id=0
    local vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
    if [ -z "$vf_pci_addr" ]; then
        echo $INVALID_VF_ID
        return
    fi
    init_db
    # just skip those already bond to vfio-pci and reserved
    #found=$(sqlite3 $DB "SELECT hostname FROM vf WHERE vf_pci_addr='$vf_pci_addr';")
    while [ -d "/sys/bus/pci/drivers/vfio-pci/$vf_pci_addr" ] || \
        [ -n "$(sqlite3 -cmd ".timeout 10000" $DB "SELECT hostname FROM vf WHERE vf_pci_addr='$vf_pci_addr';")" ]; do
         #([ -f "$RESERVED_VFS" ] && egrep -q "$vf_pci_addr$" "$RESERVED_VFS"); do
        vf_id=$(($vf_id+1))
        vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
        if [ -z "$vf_pci_addr" ]; then
            echo $INVALID_VF_ID
            return
        fi
    done
    local max_vf=$(get_max_vf $pf_dev)
    if [ $(($vf_id+1)) -ge $max_vf ]; then
        echo $INVALID_VF_ID
    else
        echo $vf_id
    fi
}
# reserve_vf(), reserve a vf for a vm
# format:
# <hostname> pf_dev vf_id vf_pci_addr
# $1 - vm hostname
# $2 - pf_dev
# $3 - vf id
# $4 - vf pci addr
# $5 - nic id, default 0
reserve_vf() {
    #TODO: lock db when finding a valid vf
    init_db
    local nic_id=0
    if [ -n "$5" ]; then
        nic_id=$5
    fi
    sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM vf WHERE hostname='$1' and nic_id='$nic_id';"
    sqlite3 -cmd ".timeout 10000" $DB "INSERT INTO vf VALUES('$1', '$nic_id', '$2', '$3', '$4');"
    #echo "$1 $2 $3 $4" >> "$RESERVED_VFS"
}

# release_vf(), release the vf for a vm from reserve vf list
# $1 - vf pci addr
release_vf() {
    local vf_pci_addr=$1
    init_db
    sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM vf WHERE vf_pci_addr='$vf_pci_addr';"

    #if [ -f "$RESERVED_VFS" ]; then
    #    sed -i "/$vf_pci_addr$/d" "$RESERVED_VFS"
    #fi
}

# set_vf(), initialize the vf to be ready for a vm use
# - set mac address
# - set vlan if needed
# $1 hostname
# $2 pf dev
# $3 max_tx_rate
# $4 nic id, default 0
set_vf () {
    local hostname=$1
    local pf_dev=$2
    local max_tx_rate=$3
    local nic_id=0
    if [ -n "$4" ]; then
        nic_id=$4
    fi

    local vf_id=$(get_vf $hostname $pf_dev $nic_id)
    local vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)

    local vlan=$(in_vlan $hostname)
    local mac=$(get_mac $hostname $nic_id)

    # 0. set pf_dev mtu to 9000
    if [ -f /sys/class/net/$pf_dev/mtu ]; then
        if [ $(cat /sys/class/net/$pf_dev/mtu) -ne 9000 ]; then
            echo "Setting $pf_dev mtu to 9000"
            ip link set dev $pf_dev mtu 9000
        fi
    fi

    # 1-(a) change the MAC address for VF to be assigned:
    echo "Setting MAC address $mac for VF $vf_id on $pf_dev"
    #ip link set dev $pf_dev vf $vf_id mac $mac spoofchk off
    ip link set dev $pf_dev vf $vf_id mac $mac
    # tagged vlan for vm1 - vm115
    if [ $vlan -eq 1 ]; then
        local vlan_id=$VLAN_ID
        if [ $nic_id = 0 ]; then
            vlan_id=$VLAN_ID
        else
            vlan_id=$VLAN1_ID
        fi
        # for iscsi boot, set vf vlan, IP address for vlan is not needed
        ip link set dev $pf_dev vf $vf_id vlan $vlan_id
        # for pv boot,  will add IP for macvlan tap device created on dedicated vlan

        # do not set VEPA because the switch doesn't support VEPA
        # echo "Set the bridging mode for $pf_dev to vepa"
        # bridge link set dev $pf_dev hwmode vepa
    # untagged vlan
    else
        # for iscsi boot, just set vf vlan to 0, IP address is not needed
        ip link set dev $pf_dev vf $vf_id vlan 0
    fi
    # max_tx_rate
    if [ $max_tx_rate -ne 0 ]; then
        echo "Setting $pf_dev VF $vf_id TX max rate to $max_tx_rate"
        ip link set dev $pf_dev vf $vf_id max_tx_rate $max_tx_rate
    fi
    # 1-(b) bind vf's driverto vfio-pci module
    # echo "Binding $pf_dev VF $vf_id($vf_pci_addr) to vfio-pci."
    # $BASE_DIR/bind_vfio-pci.sh $vf_pci_addr
    $BASE_DIR/bind_vf.sh $pf_dev $vf_id

    echo "VF $vf_id($vf_pci_addr) on $pf_dev is set for vm $hostname"
}
# unset_vf(), reset the vf to unused state for a vm
#  - unbind vf from vfio-pci module
#  - set vf vlan 0
#  - set vf mac address to 00:00:00:00:00:00
#  - unset vf max_tx_rate
# $1 vf pci addr
unset_vf () {
    local vf_pci_addr=$1
    init_db
    local s="$(sqlite3 -cmd ".timeout 10000" $DB "SELECT * FROM vf WHERE vf_pci_addr='$vf_pci_addr';")"
    set +e
    # unbind vf from vfio-pci module anyway
    sleep 3
    $BASE_DIR/unbind_vfio-pci.sh $vf_pci_addr
    sleep 3
    #if [ -f "$RESERVED_VFS" ]; then
    #if [ -n "$s" ]; then
        #local s=$(grep $vf_pci_addr "$RESERVED_VFS")
        if [ -n "$s" ]; then
            #local pf_dev=$(echo $s | awk -F '|' '{print $2}')
            #local vf_id=$(echo $s | awk -F '|' '{print $3}')
            local pf_dev=$(echo $s | awk -F '|' '{print $3}')
            local vf_id=$(echo $s | awk -F '|' '{print $4}')
            if [ -n "$pf_dev" -a -n "$vf_id" ]; then
                echo "Resetting $pf_dev vf $vf_id vlan 0, max_tx_rate 0, mac 00:00:00:00:00:00(00:01 for bnxt_en)"
                ip link set dev $pf_dev vf $vf_id vlan 0 max_tx_rate 0
                # issues and workaround:
                # - Broadcom 25Gbnxt, vf mac can't be set to 00:00:00:00:00:00, this will set to previous vf mac address
                #   so we set it to 00:00:00:00:00:01 for bnxt
                # - intel ixgbe sometime it can't remove vf mac, workaround is set it to 00:00:00:00:00:01, then 00:00:00:00:00:00
                ip link set dev $pf_dev vf $vf_id mac 00:00:00:00:00:01
                local driver=$(ethtool -i $pf_dev | sed -n '/^driver:/p' | sed 's/driver: \(.*\)/\1/')
                if [ -n "$driver" -a "$driver" != bnxt_en ]; then
                    ip link set dev $pf_dev vf $vf_id mac 00:00:00:00:00:00
                fi
                # if vf netdev is up, reset the mac and bring it down
                if [ -d "/sys/class/net/$pf_dev/device/virtfn$vf_id/net" ]; then
                    local vf_dev=$(ls /sys/class/net/$pf_dev/device/virtfn$vf_id/net)
                    if [ -n "$vf_dev" ]; then
                        if ip link show $vf_dev | grep -q "state UP"; then
                            ip link set dev $vf_dev address 00:00:00:00:00:01
                            echo "Bringing down $vf_dev"
                            ip link set $vf_dev down
                        fi
                    fi
                fi

            fi
        fi
    #fi
    set -e
}

# get vf pci addr
# $1 pf dev
# $2  vf id
get_vf_pci_addr() {
    $BASE_DIR/get_vf.sh $1 $2
}

# get max vf num of a pf
# $1 pf_dev
get_max_vf () {
    local eth_dev=$1
    if [ -f/sys/class/net/$eth_dev/device/sriov_numvfs ]; then
        cat /sys/class/net/$eth_dev/device/sriov_numvfs
    else
        echo 0
    fi
}

# get attached vf pci addr from a running vm
# $1 vm work dir
#get_vm_vf () {
#    local dir=$1
#    $BASE_DIR/hmp.sh $dir info pci
#}

########################################################################
# macvtap functions:
# get_macvtap() - get existing macvtap dev for a vm
# find_macvtap() - get a new macvtap dev
# reserve_macvtap(), reserve a macvtap dev for a vm
# release_macvtap(), delete and release the macvtap for a vm from reserve macvtap list
# set_macvtap(), set the macvtap up for a vm use
# unset_macvtap(), set the macvtap down for a vm
# get_tap_id() , get macvtap tap id

# get_macvtap() - get existing vf id for a vm
# $1 vm hostnmae
# $2 nic id, default 0
# return macvtap dev
get_macvtap() {
    local hostname=$1
    # TODO: handle multiple macvtap devices
    local nic_id=0
    if [ -n "$2" ]; then
        nic_id=$2
    fi
    init_db
    sqlite3 -cmd ".timeout 10000" $DB "SELECT macvtap_dev FROM macvtap WHERE hostname='$hostname' and nic_id='$nic_id';"
    #if [ -f "$RESERVED_MACVTAPS" ]; then
    #    grep "$hostname " $RESERVED_MACVTAPS | awk '{print $3}'
    #fi
}
# find_macvtap() - get a new macvtap dev
# return: macvtap dev
find_macvtap() {
    local id=0
    # skip those already exist and reserved
    while ip link show macvtap$id >/dev/null 2>&1 || \
        [ -n "$(sqlite3 -cmd ".timeout 10000" $DB "SELECT hostname FROM macvtap WHERE macvtap_dev='macvtap$id';")" ]; do
        #([ -f "$RESERVED_MACVTAPS" ] && egrep -q "macvtap$id$" "$RESERVED_MACVTAPS"); do
        id=$(($id+1))
    done
    echo macvtap$id
}
# reserve_macvtap(), reserve a macvtap for a vm
# format:
# <hostname> pf_dev macvtap_dev
# $1 - vm hostname
# $2 - pf_dev
# $3 - macvtap dev
# $4 - nic id, default 0
reserve_macvtap() {
    local hostname=$1
    local dev=$2
    local vlan=$(in_vlan $hostname)
    if [ "$vlan" -eq 1 ]; then
        dev=${dev}.${VLAN_ID}
    fi
    local nic_id=0
    if [ -n "$4" ]; then
        nic_id=$4
    fi
    init_db
    #sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM macvtap WHERE hostname='$1';"
    sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM macvtap WHERE hostname='$1' and nic_id='$nic_id';"
    sqlite3 -cmd ".timeout 10000" $DB "INSERT INTO macvtap VALUES('$1', '$nic_id', '$dev', '$3');"
    #echo "$1 $dev $3" >> "$RESERVED_MACVTAPS"
}

# release_macvtap(), delete and release the macvtap for a vm from reserve macvtap list
# $1 macvtap_dev
release_macvtap () {
    local macvtap_dev=$1
    if ip link show $macvtap_dev >/dev/null 2>&1; then
        echo "Deleting $macvtap_dev"
        ip link delete $macvtap_dev
    fi
    init_db
    sqlite3 -cmd ".timeout 10000" $DB "DELETE FROM macvtap WHERE macvtap_dev='$macvtap_dev';"
    # if [ -f "$RESERVED_MACVTAPS" ]; then
    #     sed -i "/$macvtap_dev$/d" "$RESERVED_MACVTAPS"
    # fi
}

# set_macvtap(), set the macvtap up for a vm use
# $1 hostname
# $2 pf_dev
# $3 macvtap_dev
# $4 max_tx_rate
# $5 nic id, default 0
set_macvtap() {
    local hostname=$1
    local pf_dev=$2
    local macvtap_dev=$3
    local max_tx_rate=$4
    local nic_id=0
    local macvtap_mode=$MACVTAP_MODE
    local vlan=$(in_vlan $hostname)

    if [ -n "$5" ]; then
        nic_id=$5
    fi
    local mac=$(get_mac $hostname $nic_id)

    local dev=$pf_dev

    # dedicated macvlan for pv boot
    # TODO: add macvlan/macvtap devices in ns(network namespaces)

    # 1) create vlan dev on pf
    local vlan_dev=${pf_dev}.${PV_VLAN_ID}
    if ! ip link show $vlan_dev >/dev/null 2>&1; then
        echo "Creating VLAN $vlan_dev on $pf_dev"
        ip link add link $pf_dev name $vlan_dev type vlan id $PV_VLAN_ID
    fi

    # 2) create macvlan dev on vlan dev
    local macvlan="macvlan$PV_VLAN_ID"
    if ! ip link show $macvlan >/dev/null 2>&1; then
        echo "Creating MAC VLAN interface $macvlan on $vlan_dev"
        # might need to set mac and mode(bridge? vepa?)  for macvlan dev
        # ip link add link $pf_dev name $macvlan address $mac type macvlan mode bridge
        # ip link add link $pf_dev name $macvlan address $mac type macvlan mode $MACVLAN_MODE
        # TODO: set separated mac address for macvlan
        ip link add link $vlan_dev name $macvlan type macvlan mode $MACVLAN_MODE
        # 3) set ip on macvlan dev
        local host_pv_vlan_ip=$(get_host_vlan_ip $PV_VLAN_ID)
        if [ -z "$host_pv_vlan_ip" ]; then
            echo "Could not get IP address for $macvlan"
            echo "Please set internal DNS server in 6OP lab."
            return 1
        fi
        echo "Adding IP address $host_pv_vlan_ip/$PV_VLAN_SUBNET_MASK on interface $macvlan"
        ip addr add $host_pv_vlan_ip/$PV_VLAN_SUBNET_MASK dev $macvlan
    fi

    # 4) bring up vlan and macvlan
    echo "Bringing up VLAN $vlan_dev"
    ip link set $vlan_dev up
    echo "Bringing up MAC VLAN $macvlan"
    ip link set $macvlan up

    if [ "$vlan" -eq 1 ]; then

        local vlan_id=
        if [ "$nic_id" = 0 ]; then
            vlan_id=$VLAN_ID
        else
            vlan_id=$VLAN1_ID
        fi

        # vlan for vm macvtap device
        if ! ip link show $pf_dev.$vlan_id >/dev/null 2>&1; then
            # add vlan on pf dev, vlan name is <pf dev>.<vlan id>
            echo "Adding vlan $pf_dev.$vlan_id on $pf_dev"
            ip link add link $pf_dev name $pf_dev.$vlan_id type vlan id $vlan_id
            # only set ip a vlan 674 to get access to vm from host
            if [ "$nic_id" = 0 ]; then
                local host_vlan_ip=$(get_host_vlan_ip $vlan_id)
                if [ -z "$host_vlan_ip" ]; then
                    echo "Could not get IP address for $pf_dev.$vlan_id"
                    echo "Please set internal DNS server in 6OP lab."
                    return 1
                fi
                echo "Setting $pf_dev.$vlan_id IP $host_vlan_ip/$VLAN_SUBNET_MASK"
                ip addr add $host_vlan_ip/$VLAN_SUBNET_MASK dev $pf_dev.$vlan_id
            fi

            echo "Bringing up $pf_dev.$vlan_id"
            ip link set $pf_dev.$vlan_id up
        fi


        # old steps
        # # 1) create vlan device of pf
        # if ! ip link show $pf_dev.$vlan_id >/dev/null 2>&1; then
        #     # add vlan on pf dev, vlan name is <pf dev>.<vlan id>
        #     echo "Adding vlan $pf_dev.$vlan_id on $pf_dev"
        #     ip link add link $pf_dev name $pf_dev.$vlan_id type vlan id $vlan_id
        #     echo "Bringing up $pf_dev.$vlan_id"
        #     ip link set $pf_dev.$vlan_id up
        # fi
        # # 2) create macvlan dev
        # if [ "$nic_id" = 0 ]; then
        #     if ! ip link show macvlan$vlan_id >/dev/null 2>&1; then
        #         echo "Adding macvlan$vlan_id on $pf_dev.$vlan_id"
        #         ip link add macvlan$vlan_id link $pf_dev.$vlan_id type macvlan mode bridge
        #         # 3) set ip on macvlan
        #         local host_vlan_ip=$(get_host_vlan_ip)
        #         echo "Setting macvlan$vlan_id IP $host_vlan_ip/$VLAN_SUBNET_MASK"
        #         ip addr add $host_vlan_ip/$VLAN_SUBNET_MASK dev macvlan$vlan_id
        #         # 4) set macvlan dev up
        #         echo "Bringing up macvlan$vlan_id"
        #         ip link set macvlan$vlan_id up
        #     fi
        # fi

        dev=$pf_dev.$vlan_id
    fi
    # create macvtap
    if ! ip link show $macvtap_dev >/dev/null 2>&1; then
        echo "Adding $macvtap_dev@$dev address $mac type macvtap mode $macvtap_mode"
        #echo ip link add link $dev name $macvtap_dev address $mac type macvtap mode "$macvtap_mode"
        ip link add link $dev name $macvtap_dev address $mac type macvtap mode "$macvtap_mode"
        #TODO: set max_tx_rate
        echo "Created ${macvtap_dev}@${dev} for vm $hostname"
    fi
    echo "Bringing up $macvtap_dev@${dev} for vm $hostname"
    ip link set $macvtap_dev up
}
# unset_macvtap(), set the macvtap down for a vm
# $1 macvtap dev
unset_macvtap() {
    local macvtap_dev=$1
    if ip link show $macvtap_dev >/dev/null 2>&1; then
        echo "Bringing down $macvtap_dev for vm $hostname"
        ip link set $macvtap_dev down
    fi
}

# get macvtap device tap id
# $1 - macvtap dev
get_tap_id() {
    if [ -f /sys/class/net/$1/ifindex ]; then
        cat /sys/class/net/$1/ifindex
    fi
}

#################################################################

# nic functions

# clean up vf and macvtap
# $1 vf pci addr
# $2 macvtap dev
clean_nic () {
    sleep 2
    unset_macvtap $2
    # release FDs
    echo "Releasing FDs"
    eval "exec $TAP_FD>&-"
    eval "exec $VHOST_NET_FD>&-"
    release_macvtap $2
    unset_vf $1
    release_vf $1
}

# $1 hostname
clean_nics () {
    local hostname=$1
    local pf_dev=$2
    local vf_id
    local macvtap_dev
    local nic_id

    # wait for qemu process gone 
    sleep 3

    for nic_id in 1 0; do
        vf_id=$(get_vf $hostname $pf_dev $nic_id)
        macvtap_dev=$(get_macvtap $hostname $nic_id)
        if [ -n "$macvtap_dev" ]; then
            unset_macvtap $macvtap_dev
            # release FDs
            echo "Releasing FDs"
            if [ "$nic_id" = 0 ]; then
                eval "exec $TAP_FD>&-"
                eval "exec $VHOST_NET_FD>&-"
            else
                eval "exec $TAP1_FD>&-"
                eval "exec $VHOST_NET1_FD>&-"
            fi
            release_macvtap $macvtap_dev
        fi
        if [ -n "$vf_id" ]; then
            local vf_pci_addr=$(get_vf_pci_addr $pf_dev $vf_id)
            unset_vf $vf_pci_addr
            release_vf $vf_pci_addr
        fi
    done

}

# get mac
# $1 vm hostname
# $2 nic id, default 0
get_mac() {
    local hostname=$1
    local nic_id=0
    if [ -n "$2" ]; then
        nic_id=$2
    fi
    local vlan=
    local prefix=
    vlan=$(in_vlan $hostname)
    if [ "$vlan" -eq 1 ]; then
        prefix=$MAC_PREFIX_VLAN
    elif [ "$vlan" -eq 0 ]; then
        prefix=$MAC_PREFIX
    fi
    local id=${hostname[@]:2}
    local index=$((($id-1)*2))
    if [ "$nic_id" = 1 ]; then
        index=$(($index+1))
    fi
    echo -n $prefix
    #printf "%04x\n" $index | sed -e 's/\(..\)/:\1/g'
    printf "%04x" $index | sed -e 's/\(..\)/:\1/g'
}
#################################################################

CMDS="gcc git make curl wget qemu-system-x86_64"
RPMS="glibc-headers qemu-block-iscsi bind-utils hostname sqlite"

check () {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root" >&2
        exit 1
    fi
    local cmd
    for cmd in $CMDS; do
        if ! which $cmd >/dev/null 2>&1; then
            echo "$cmd is missing." >&2
            exit 1
        fi
    done
    local r
    for r in $RPMS; do
        if ! rpm -q $r >/dev/null 2>&1; then
            echo "Package $r is missing." >&2
            exit 1
        fi
    done
}

###################################################################
# ovmf files built from OCI edk2 src
QEMU_IMAGE_BINARIES=http://ca-sysinfra604.us.oracle.com/systest/kvm_images/qemu-img-binaries.tar.gz

INVALID_VF_ID="-1"

# mac address prefix for ol1 - ol46 in vlan617
MAC_PREFIX="00:18:8b:0b"
# mac address prefix for vm1 - vm115 in vlan674
MAC_PREFIX_VLAN="00:18:8b:4c"

# vm vlan for vf, macvtap for iSCSI boot
# 2 vlans for 2 vm vnics
VLAN_ID=674
VLAN_SUBNET_MASK=21

VLAN1_ID=678


# dedicated vlan for qemu/iSCSI backed for PV boot
PV_VLAN_ID=672
PV_VLAN_SUBNET_MASK=22

MACVLAN_MODE="bridge"
MACVTAP_MODE="bridge"

TARGET_IP=10.196.242.119
TARGET_IP_VLAN=10.197.0.8
TARGET_IP_PV_VLAN=10.196.248.8

DB_DIR=~/.qemu
DB=$DB_DIR/vm.db
#RESERVED_VFS=/var/run/vfs
#RESERVED_MACVTAPS=/var/run/macvtaps

TAP_FD=10
VHOST_NET_FD=11
TAP1_FD=12
VHOST_NET1_FD=13
