<!-- wip-kind: archive -->
# WIP archive

---

# Completed items pruned from WIP.md on 10/06/2026 17:10 CT — 2 item(s)

Line-level close-out: finished and ticked, so they left the open list. The sections
they came from are still live and stayed behind.

- [x] Rebuild, reinstall on the `clean` snapshot, run `tools/win_drive.sh` — prove
  F13 assigns without crashing and that a press keys the rig.
  VERIFIED 10/06: the F13 fix (`_pollsTheKey`, client/lib/ptt.dart) is in tag v0.8.0, whose CI build went green 09/05 09:55Z and produced the installer artifacts; the drive run itself was not re-run (VM 109 stopped, no host)
- [x] **Cut the web build to admin-only** (his call: "Admin only, no operating") —
  accounts, sessions, lockdown, KILL TRANSMIT, read-only status. No operating
  surface in a browser. NOT STARTED.
  VERIFIED 10/06: client/lib/main.dart:56 `if (kIsWeb && !_shootOperating)` gates the web build to admin, guarded by tools/check_web_is_admin_only.py; both present in tag v0.8.0
