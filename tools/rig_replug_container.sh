#!/usr/bin/env bash
# Does the CONTAINERISED station survive a replug of the radio?
#
# Unbind/rebind both USB devices from the kernel's usb driver - the same
# udev remove/add a physical replug gives, without touching the hypervisor
# passthrough. Run on the box that holds the devices.
#
# ⚠️ This restarts the radio link and drops client sessions. Never run it while
# Joe is operating.
set -uo pipefail
CP=2-1   # CP2105, CAT
CO=2-2   # PCM2903C, codec
say() { printf '\n== %s\n' "$*"; }
health() { curl -s -m 5 http://127.0.0.1:5102/api/health || echo '(no answer)'; }
fds() {
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' hamdeck-go 2>/dev/null) || return
    ls -l /proc/"$pid"/fd 2>/dev/null | grep -E 'ttyUSB|ttyRIG|snd' | awk '{$1=$2=$3=$4=$5=$6=$7=$8=""; print}'
}

say "BEFORE"; echo "ttyRIG -> $(readlink /dev/ttyRIG)"; health; echo; fds

say "UNPLUG (unbind)"
for d in $CP $CO; do
    # Test for the DRIVER link, not the device directory - unbinding leaves the
    # device in /sys/bus/usb/devices, so guarding on the dir skips every rebind
    # and leaves the station off the air.
    [ -e "/sys/bus/usb/devices/$d/driver" ] && echo -n "$d" > /sys/bus/usb/drivers/usb/unbind
done
sleep 3
echo "ttyRIG -> $(readlink /dev/ttyRIG 2>&1)"; echo "container: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' hamdeck-go)"; fds

say "PLUG BACK IN (rebind)"
for d in $CP $CO; do
    [ -e "/sys/bus/usb/devices/$d/driver" ] || echo -n "$d" > /sys/bus/usb/drivers/usb/bind
done
sleep 8
echo "ttyRIG -> $(readlink /dev/ttyRIG 2>&1)"
echo "container: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' hamdeck-go)"
fds
say "AFTER"; health; echo
# ⚠️ Say WHICH check failed. A summary line that prints one number while a
# different assertion is what tripped is how a gate lies about itself.
stale=$(fds | grep -c deleted)
rig=no; health | grep -q '"rig_connected":true' && rig=yes
echo "rig_connected after replug: $rig   stale fds: $stale"
if [ "$rig" = yes ] && [ "$stale" -eq 0 ]; then
    echo "PASS: the station recovered the radio by itself"
else
    [ "$rig" = no ] && echo "FAIL: rig_connected is false - the host is serving with no radio"
    [ "$stale" -gt 0 ] && echo "FAIL: $stale stale (deleted) device handles"
    exit 1
fi
