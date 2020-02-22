## Create LUN using OCI Linux image on iSCSI target

Login Linux iSCSI target server which is running targetcli

Locate the OCI OL and Ubuntu OS images
```
find /OCI_images
```

Use the the utility 'create-lun' to create iSCSI LUN from the OS image
```
Usage:
  create_lun.sh -n [hostname] -o [OS name] -i [image location]
  Options:
    -n [hostname], Available hostname: ol1-ol36, vm1-vm100
    -o [OS name], OL6/OL7/OL8/Ubuntu14/Ubuntu16/Ubuntu18
    -i [Image], e.g /OCI_images/Oracle-Linux-7.7-2019.10.16-773/output.QCOW2
    -s, enable systemd debug with 'systemd.log_level=debug'
    -m, use default cloud-init config and metadata service IP 169.254.169.254'
    -p for pv boot only meaning leaving 169.254.0.2 as iscsi target which can't be accessed.

Examples:
  To create a LUN from OL7
    # create-lun -n ol1 -o OL7 -i /OCI_images/OL7.4-20170926
  To create a LUN from Ubuntu16 image
    # create-lun -n ol1 -o Ubuntu16 -i /OCI_images/Ubuntu16/20171006/livecd.ubuntu-cpc.oracle_bare_metal.img
  To create a lun from OL7 and boot it in PV mode only, please add "-p" option
    # create-lun -n ol1 -o OL7 -i /OCI_images/OL7.4-20170926 -p
```
## Start the VM on KVM hosting server
Login KVM hosting server as root user

Check:
- UEK4QU5(4.1.12-103.7.1+) and above,  "intel_iommu=on iommu=pt" is in kernel cmdline.
- The servers should have ethernet device connected to 6OP private network (10.196.240.0/21) and lspci -vvv should show the device SR-IOV capability is enabled.
- qemu 2.9+ is installed.
- Install required packages for building customized iPXE ROM files.
```
yum install -y subversion git gcc make xz-devel glibc-devel
```

### Start a VM
Use 'start.sh' script to start the VM
```
Usage:
./start.sh -a [VM Hostname] -d [Ethernet device name]
Options:
  -a [VM hostname], available hostnames:
     ol1 - ol36
     vm1 - vm115 in tagged vlan
  -P [VM working directory], default: ./<vm hostname>
  -p pause the VM before launching, the vm will enter into initial paused state(prelaunch)
  -H start handle_vents.py after launching the VM for SR-IOV live migration datapath switching
  -I migration-listen mode, start vm with -incoming tcp:0:<port> on dst host for incoming migration
  -c [number of ocpus], default: 2
  -m [memory size in MB], default: 2048 MB
  -d [Ethernet device name], must support SR-IOV, on which create VFs or macvtap device example: eno2
  -b [iscsi|pv], boot volume, iSCSI boot inside VM or PV(virtio-scsi-pci/scsi-block), default: iscsi
  -n [virtio|vf|none|both], nic: virtio-net or Virtual Function(SR-IOV) or both or none, default: vf
         when nic is none and boot volume is iscsi, the vm will be put in paused(prelaunch) state
  -s start virtio-net nic with standby=on
  -r [max_tx_rate], macvtap or VF max_tx_rate, default is 0(unlimit), unit(Mb/s)
  -i [customized ipxe script file], default is boot-iscsi.ipxe.template or boot-pv.ipxe.template

Samples:
  -Start a VM(iSCSI boot volume) with a vfio nic
       ./start.sh -a ol1 -d eno2 -b iscsi -n vf -P ~/vms/ol1
  -Start a VM(PV boot volume) with a virtio-net nic
       ./start.sh -a ol1 -d eno2 -b pv -n virtio -P ~/vms/ol1
  -Start a VM(iSCSI boot volume) with a standby enabled virtio-net nic
       ./start.sh -a ol1 -d eno2 -b iscsi -n virtio -s -P ~/vms/ol1
  -Start a VM(PV boot volume) with a standby enabled virtio-net nic,
   and handle SR-IOV datapath switching events
       ./start.sh -a vm1 -d eno2 -b pv -n virtio -s -H -P ~/vms/vm1
  -Start a VM(iSCSI boot volume) with a standby enabled virtio-net nic in migration listen mode,
   and handle SR-IOV datapath switching events
       ./start.sh -a vm1 -d eno2 -b iscsi -n virtio -s -I -H -P ~/vms/vm1
  -Create a VM(iSCSI boot volume) with a vfio nic, VM will enter into prelaunch state
       ./start.sh -a vm1 -d eno2 -b iscsi -n vf -p -P ~/vms/vm1
  -Create a VM(PV boot volume) without net device, VM will enter into prelaunch state
       ./start.sh -a vm1 -d eno2 -b pv -n none -p -P ~/vms/vm1
```

Run ./start.sh -h for new options and latest samples.

Notes:
- The ethernet device must connect to 6OP private network, and the SR-IOV is enabled for the ethernet device.
- First time start a VM, it takes a little bit longer to build customized iPXE ROM files.
- Do NOT start VM with same hostname multiple times at same time, the VM file system may corrupt and may not boot again.
- Do NOT run I/O workload on VM rootfs. If you need to test I/O workload on iSCSI disk, attach extra iSCSI disks from zfs storage.

### Other scripts

- stop.sh - stop VM by sending HMP system_powerdown command
- cont.sh - continue the VM in paused status.
- vf.sh - bind/unbind VF, hot add/remove VF.
- virtio-net.sh - hot add/remove virtio-net.
- macvtap.sh - bring virtio-net backend macvtap device up or down.
- migrate.sh - live migrate
- monitor_events.sh - monitor vm QMP events
- handle_events.py - handle SR-IOV live migaration datapath switching related FAILOVER events.


### QMP and HMP
QMP and HMP shell
```
# ./qmp-shell.sh ~/myvms/ol1
# ./hmp-shell.sh ~/myvms/ol2
```
QMP and HMP commands
```
# ./qmp.sh ~/myvms/ol1 "query-status"
# ./hmp.sh ~/myvms/ol1 "info status"
```

### Access VM serial console
```
# ./serial.sh ~/myvms/ol1
```
### SR-IOV Live migration

Source host: start VM with standby feature enabled virtio-net nic, handle QMP events for SR-IOV live migration datapath switching
sr-iov live migration works with both pv and iscsi boot volume.
```
./start.sh -a vm1 -P ~/myvms/vm1 -d eno3d1 -n virtio -s -b pv -N 2 -H
```
When vm is up,  QMP event hander should hot add vf and bring macvtap down.

Dest host: start vm in migration listen mode, handle QMP events for SR-IOV live migration datapath switching
```
./start.sh -a vm1 -P ~/myvms/vm1 -d eno3d1 -n virtio -s -b pv -N 2 -H -I
```
Source host: hot remove VF from VM
```
./vf.sh -P ~/myvms/vm1 -o del -n 1
./vf.sh -P ~/myvms/vm1 -o del -n 0
```

Once VF is removed, QMP event handler will bring macvtap up and unset vf.

Source host: migrate VM
```
./migrate.sh -P ~/myvms/vm1 -d <dest host hostname/IP>
```
migration will take time to complete. hmp cmd 'info migrate' to check the migration status.

```
./hmp.sh vm1 "info migrate"
```
Dest host: vm resumed.
vm status changes from inmigrate to running, 'RESUME" event is sent.

Dest host: set VF and hot add VF
```
./vf.sh -P ~/myvms/vm1 -o up -n 1
./vf.sh -P ~/myvms/vm1 -o add -p -n 1
./vf.sh -P ~/myvms/vm1 -o up -n 0
./vf.sh -P ~/myvms/vm1 -o add -p -n 0
```
