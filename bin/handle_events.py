#!/usr/bin/python
#
# handle QMP events for sr-iov lm datapath switching
#

from __future__ import print_function
import sys
import os
import json
import threading
import time
import subprocess

base_path = os.path.dirname(os.path.abspath(__file__))
qmp_path = os.path.join(base_path, "..", "qmp")
sys.path.insert(0, qmp_path)

import qmp

class colors:
    '''Colors class:
    reset all colors with colors.reset
    two subclasses fg for foreground and bg for background.
    use as colors.subclass.colorname.
    i.e. colors.fg.red or colors.bg.green
    also, the generic bold, disable, underline, reverse, strikethrough,
    and invisible work with the main class
    i.e. colors.bold
    '''
    reset='\033[0m'
    bold='\033[01m'
    disable='\033[02m'
    underline='\033[04m'
    reverse='\033[07m'
    strikethrough='\033[09m'
    invisible='\033[08m'
    class fg:
        black='\033[30m'
        red='\033[31m'
        green='\033[32m'
        orange='\033[33m'
        blue='\033[34m'
        purple='\033[35m'
        cyan='\033[36m'
        lightgrey='\033[37m'
        darkgrey='\033[90m'
        lightred='\033[91m'
        lightgreen='\033[92m'
        yellow='\033[93m'
        lightblue='\033[94m'
        pink='\033[95m'
        lightcyan='\033[96m'
    class bg:
        black='\033[40m'
        red='\033[41m'
        green='\033[42m'
        orange='\033[43m'
        blue='\033[44m'
        purple='\033[45m'
        cyan='\033[46m'
        lightgrey='\033[47m'

def run_cmd(cmd, success_return_code=(0,)):
    if not isinstance(cmd, list):
        raise Exception("Only accepts list!")
    cmd = [str(x) for x in cmd]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, close_fds=True)
    (stdoutdata, stderrdata) = proc.communicate()
    if proc.returncode not in success_return_code:
        raise RuntimeError('Command: %s failed (%s): stderr: %s stdout: %s'
                           % (cmd, proc.returncode, stderrdata, stdoutdata))
    return str(stdoutdata)

def retry_cmd(cmd, interval=5, count=3):
    # retry if failed
    for i in range(1, count):
        try:
            output = run_cmd(cmd)
            return output
        except:
            time.sleep(interval)
    # retry for the last time
    return run_cmd(cmd)

def pprint(qmp):
    indent = 4
    jsobj = json.dumps(qmp, indent=indent)
    print(str(jsobj))

class EventHandler(threading.Thread):
    def __init__(self, vm, event):
        threading.Thread.__init__(self)
        self.vm = vm
        self.event = event

    def run(self):
        ev = self.event
        vm = self.vm
        event = ev['event']
        timestamp = ''.join([str(ev['timestamp']['seconds']), str(ev['timestamp']['microseconds'])])
        # FAILOVER and DEVICE_DELETED
        # do not handle RESUME event for datapath switching
        # if event.find('FAILOVER_') == 0 or event == 'DEVICE_DELETED' or event == 'RESUME':
        if event.find('FAILOVER_') == 0 or event == 'DEVICE_DELETED':

            device = None
            device_id = None
            path = None
            enabled = None

            s = "[%s %s" % (timestamp, event)

            if 'data' in ev:
                if 'device' in ev['data']:
                    device = ev['data']['device']
                    device_id = device[-1] #vf0, net1, so device_id is 0 or 1
                    print(device)
                    print(device_id)
                    s = "%s device: %s" % (s, device)
                if 'path' in ev['data']:
                    path = ev['data']['path']

                if 'enabled' in ev['data']:
                    enabled = ev['data']['enabled']
                    s = "%s, enabled: %s" % (s, enabled)

            s = "%s] " % (s)
            color = get_color()

            def _print(d):
                print("%s%s %s%s" % (color, s, d, colors.reset))

            _print("Event received, handling")
            if device is None:
                _print("device is missing in event, event handling skipped.")
                return

            vf_sh = os.path.join(base_path, 'vf.sh')
            macvtap_sh = os.path.join(base_path, 'macvtap.sh')

            # do not handle resume event as we don't know it's resumed from migrate or other paused state.
            # resume from migration, bring up vf(set mac, vlan, bind to vfio-pci), and hot add vf
            # if event == 'RESUME':
            #     _print("resumed from live migration")
            #     _print("1-(a) change the MAC address for VF to be assigned, set vlan")
            #     _print("1-(b) rebind VF's driver to vfio-pci")
            #     output = run_cmd([vf_sh, "-P",  vm_dir, "-o", "up"])
            #     _print(output)
            #     # attach vf
            #     _print("1-(c) hot add a VF with 'x-failover-primary' property set to true")
            #     output = run_cmd([vf_sh, "-P",  vm_dir, "-o", "add"])
            #     _print(output)

            # virtio plug, bring up vf(set mac, vlan, bind to vfio-pci), and hot add vf
            #if event == 'FAILOVER_PLUG_PRIMARY' and device == 'net0':
            if event == 'FAILOVER_PLUG_PRIMARY' and device.find('net') == 0:
                #print("Event: %s, device: %s" % (event, device))
                _print("1-(a) change the MAC address for VF to be assigned, set vlan")
                _print("1-(b) rebind VF's driver to vfio-pci")
                output = run_cmd([vf_sh, "-P",  vm_dir, "-o", "up", "-n", device_id])
                _print(output)
                # attach vf
                _print("1-(c) hot add a VF with 'x-failover-primary' property set to true")
                output = run_cmd([vf_sh, "-P", vm_dir, "-o", "add", "-p", "-n", device_id])
                _print(output)

            # failover primary changed, vf is enabled, bring macvtap down
            #if event == 'FAILOVER_PRIMARY_CHANGED' and device == 'vf0' and enabled is True:
            if event == 'FAILOVER_PRIMARY_CHANGED' and device.find('vf') == 0 and enabled is True:
                #_print("Event: %s, device: %s, enabled: %s" % (event, device, enabled))
                _print("1-(d) once VF shows up in the guest, a corresponding FAILOVER_PRIMARY_CHANGED VF 'enabled' is sent.")
                _print("Hippovisor should remove the conflict MAC filter for VF to activate its datapath later: ip link set macvtap down")
                output = run_cmd([macvtap_sh, "-P", vm_dir, "-o", "down", "-n", device_id])
                _print(output)

            # failover primary changed,  vf disabled, bring up macvtap
            #if event == 'FAILOVER_PRIMARY_CHANGED' and device == 'vf0' and enabled is False:
            if event == 'FAILOVER_PRIMARY_CHANGED' and device.find('vf') == 0 and enabled is False:
                #_print("Event: %s, device: %s, enabled: %s" % (event, device, enabled))
                _print("2-(b) or 3-(b) Receiving the FAILOVER_PRIMARY_CHANGED VF 'disable' event")
                _print("Activate virtio datapath: ip link set macvtap up")
                output = run_cmd([macvtap_sh, "-P", vm_dir, "-o", "up", "-n", device_id])
                _print(output)

            # vf deviced deleted, bring down vf(reset mac, vlan, unbind from vfio-pci)
            #if event == 'DEVICE_DELETED' and device == 'vf0':
            if event == 'DEVICE_DELETED' and device.find('vf') == 0:
                _print("2-(c) or 3-(c) wait for the completion of VF's removal from guest and then QEMU")
                _print("Event: %s, device: %s" % (event, device))
                _print("2-(d) or 3-(d) upon confirming successful hot removal, clear the MAC address for VF to complete datapath switching, then unbind the VF from vfio-pci")
                output = run_cmd([vf_sh, "-P",  vm_dir, "-o", "down", "-n", device_id])
                _print(output)

            # virtio unplug, hot remove vf
            #if event == 'FAILOVER_UNPLUG_PRIMARY' and device == 'net0':
            if event == 'FAILOVER_UNPLUG_PRIMARY' and device.find('net') == 0:
                _print("3-(a) If QEMU detects virtio_net driver removal, it would initiate a hot remove vf")
                _print("immediately hot remove the VF through QMP")
                _print("Event: %s, device: %s" % (event, device))
                output = run_cmd([vf_sh, "-P",  vm_dir, "-o", "del", "-n", device_id])
                _print(output)
            _print("Event handled.")

def get_vm_info(vm_dir):
    vm = {}
    vm['hostname'] = open(os.path.join(vm_dir, "hostname"), "r").read().strip()
    vm['pf_dev'] = open(os.path.join(vm_dir, "pf_dev"), "r").read().strip()
    return vm

cmd, args = sys.argv[0], sys.argv[1:]

def usage():
    return '''
usage:
    %s [-h] [-P <vm working dir>]
''' % cmd

def usage_error(error_msg = "unspecified error"):
    sys.stderr.write('%s\nERROR: %s\n' % (usage(), error_msg))
    sys.exit(1)

def die(msg):
    sys.stderr.write('ERROR: %s\n' % msg)
    sys.exit(1)

vm_dir = None
socket_path = None

if len(args) > 0:
    if args[0] == "-h":
        sys.stdout.write(usage())
        sys.exit(0)
    elif args[0] == "-P":
        try:
            vm_dir = args[1]
        except:
            usage_error("missing argument: vm working dir");
        args = args[2:]
    else:
        usage_error("missing argument: vm working dir");
else:
    usage_error("missing argument: vm working dir");

socket_path = os.path.join(vm_dir, "write-qemu", "monitor-event.sock")

#if not os.path.exists(socket_path):
#    usage_error("QMP monitor socket %s not found" % socket_path);

while not os.path.exists(socket_path):
    print("%s not found, waiting" % socket_path)
    time.sleep(1)

vm = get_vm_info(vm_dir)
# colors for threads info output
thread_colors = [ colors.fg.red, colors.fg.cyan, colors.fg.orange, colors.fg.blue, colors.fg.green, colors.fg.pink ]
color_id = 0
def get_color ():
    global color_id
    color = thread_colors[color_id]
    color_id += 1
    if color_id >= len(thread_colors):
        color_id = 0
    return color

try:
    srv = qmp.QEMUMonitorProtocol(socket_path)
    srv.connect()
    print("Start handling QMP events for SR-IOV live migration datapath switching.")
    print()
    while True:
        ev = srv.pull_event(True)
        if ev:
            print("New event:")
            pprint(ev)
            eh = EventHandler(vm, ev)
            eh.start()
except qmp.QMPConnectError:
    die('QMP connetion error')
except qmp.QMPCapabilitiesError:
    die('Could not negotiate capabilities')

# whole test:
# 1. TODO: start vm using start.sh
# 2. start this test.

# main: monitor qmp events
# - keep checking qmp monitor sock file exists.
# - keep tracking qmp events
# - start new thread upon event

# new thread:  datapath switching and validation
# - datapath switching actions: hot add/del vf, bing up/down macvtap
# - validate failover in VM

