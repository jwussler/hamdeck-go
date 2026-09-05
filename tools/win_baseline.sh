#!/usr/bin/env bash
# Baselines for the Windows test rig: freeze one, list them, go back to one.
#
# ⚠️ THE SNAPSHOT LIVES OUTSIDE WINDOWS, AND THAT IS THE WHOLE POINT. An in-guest
# tool - Deep Freeze, Reboot Restore Rx and friends - is a driver running inside
# the machine under test: it can be defeated by the thing you are testing, it
# changes the environment you are measuring, and it gives you one baseline. This
# is the hypervisor rolling a copy-on-write disk back in seconds, with as many
# named baselines as you want and nothing inside the guest to interfere.
#
# ⚠️ AND "CLEAN" MEANS SOMETHING SPECIFIC HERE: a machine that has never had
# developer tooling or a Visual C++ redistributable on it. A box that already has
# the runtime cannot tell you whether your installer ships what it needs - which
# is exactly how a Windows build that could not start on anybody else's machine
# passed for weeks on the developer's own.
#
#   tools/win_baseline.sh list
#   tools/win_baseline.sh reset [name]     roll back (default: clean)
#   tools/win_baseline.sh freeze <name> "why this is a baseline"
set -euo pipefail
VMID="${WIN_TEST_VMID:-109}"
PVE="${WIN_TEST_PVE:-pve}"
HOST="${WIN_TEST_HOST:-192.168.40.168}"
CMD="${1:-list}"

running() { ssh "$PVE" "qm status $VMID" 2>/dev/null | grep -q running; }

wait_for_ssh() {
    for i in $(seq 1 60); do
        timeout 3 bash -c "echo > /dev/tcp/$HOST/22" 2>/dev/null && { echo "   ssh up after $((i*5))s"; return 0; }
        sleep 5
    done
    echo "   it never came back on ssh"; return 1
}

case "$CMD" in
list)
    ssh "$PVE" "qm listsnapshot $VMID"
    ;;

reset)
    NAME="${2:-clean}"
    # ⚠️ STOPPED FIRST. A snapshot taken without vmstate cannot be rolled into a
    # running machine, and Proxmox refuses rather than corrupting it.
    if running; then
        echo "== stopping the box"
        ssh "$PVE" "qm shutdown $VMID --timeout 90" >/dev/null 2>&1 || ssh "$PVE" "qm stop $VMID" >/dev/null 2>&1
        sleep 5
    fi
    echo "== rolling back to '$NAME'"
    ssh "$PVE" "qm rollback $VMID $NAME"
    echo "== starting it"
    ssh "$PVE" "qm start $VMID" >/dev/null 2>&1
    wait_for_ssh
    echo "the box is back at '$NAME' - as if the last install never happened"
    ;;

freeze)
    NAME="${2:?usage: win_baseline.sh freeze <name> \"why\"}"
    WHY="${3:-baseline taken $(date -u +%Y-%m-%dT%H:%MZ)}"
    # ⚠️ Frozen with the machine STOPPED, so the disk is quiet and the snapshot
    # is a state you can actually return to rather than a half-written one.
    if running; then
        echo "== stopping the box so the snapshot is consistent"
        ssh "$PVE" "qm shutdown $VMID --timeout 90" >/dev/null 2>&1 || ssh "$PVE" "qm stop $VMID" >/dev/null 2>&1
        sleep 5
    fi
    ssh "$PVE" "qm snapshot $VMID $NAME --description \"$WHY\""
    echo "frozen as '$NAME'"
    ssh "$PVE" "qm listsnapshot $VMID"
    ;;

*)
    sed -n '2,25p' "$0"
    exit 2
    ;;
esac
