# HamDeck Go — work in flight  (09/05/2026, overnight)

## Done this session

### The F13 crash is diagnosed and fixed
Reproduced on the clean Windows 11 box (VM 109) by driving the installed panel:
choosing **F13** in SETUP killed the process. Windows Error Reporting names the
cause exactly:

    P1: hamdeck_panel.exe
    P4: hotkey_manager_windows_plugin.dll
    P8: c0000409          <- __fastfail, a NATIVE abort

`c0000409` is a fail-fast, not a catchable exception — **no Dart `try/catch` can
ever guard it**, which is why the earlier serialise-and-clear mitigation did not
help. It was never the unregister path: from "Off" that path is skipped, and the
abort is inside *register*.

**Fix:** on Windows the plugin is no longer asked to register anything. The key
is polled with `GetAsyncKeyState` — the same call already used for the release
edge — so one mechanism gives both edges, works while the panel is in the
background, and cannot abort the process. See `GlobalPtt._pollsTheKey` and
`_startEdgeWatch` in `client/lib/ptt.dart`.

⚠️ **This changes what a key costs, so the chooser now says the true thing per
platform.** A *registered* key is taken from every other application; a *polled*
key is only watched and still reaches whatever has focus — so on Windows,
pressing F9 in a logger would ALSO key the rig. `GlobalPtt.choicesFor()` states
that instead of the old, now-wrong warning.

### The mark is on the app at last
The app was shipping **Flutter's own logo** as its Windows icon — that is the
blue Flutter mark in every screenshot's taskbar — the installer had no icon, and
the Linux `.desktop` named an icon nothing installed. Now wired: Windows
`app_icon.ico`, macOS appiconset, web favicon/PWA, Inno `SetupIconFile` +
`WizardSmallImageFile` + explicit shortcut `IconFilename`, and hicolor PNGs in
the `.deb`. Window title is "HamDeck Panel", not the build-target name
`hamdeck_panel`.

**Gate:** `tools/check_branding.py`, wired into `tools/preflight.sh`. Proven to
fail on demand by restoring Flutter's icon and the old title — it refused, then
passed again once restored.

### Driving Windows actually works now
Two failures had made every previous drive a fiction:
- `win11/sendtext.sh` opened **one ssh per keystroke**, so 25 characters took 25
  seconds and Windows raised the Start menu mid-password. Now one connection,
  paced at 20 keys/sec (dumping them all at once drops the string entirely — the
  emulated keyboard has a buffer).
- **`qm monitor mouse_move` is RELATIVE**, always, even though this guest's
  active pointer is an absolute HID tablet. The tablet accumulates the deltas in
  an unbounded counter, so one big negative "home" move pushed it past -40000 and
  nothing brought it back. Every click landed nowhere and the typing that
  followed went to whatever else had focus. Pointing now happens **inside the
  operator's session** via `tools/win_ui.ps1` (SetCursorPos, reads the pointer
  back). Keyboard stays on the hypervisor.

Helpers moved into the repo: `tools/win_sendtext.sh`, `tools/win_click.sh`,
`tools/win_ui.ps1`, `tools/win_ui_run.ps1`. `tools/win_drive.sh` now asserts the
panel survives being given F13 and that the key reaches the host.

### Proven end to end on Windows
`POST /api/auth/login (48ms)` from the installed panel to a host on shack — the
first real connection from a Windows install. Operating surface renders: 40M
LSB, meter, link 0 ms.

### The operating surface really was cutting controls off
Reported as "the panel just stops" - MON, COMP, ATU and THIS STATION sliced at
the bottom edge with no way to reach them. Two separate faults, both found by
rendering it rather than reasoning about it:

- ⚠️ **`IntrinsicHeight` under-reported the row height**, so the surface was
  forced to the viewport and the cards **clipped internally instead of
  scrolling**. Removing it (columns size to their content now, `minHeight` still
  fills a short window) makes the scroll view actually scroll.
- ⚠️ **The scrollbar was being painted at rgb(15,17,20) on a rgb(14,16,19)
  ground** - one value of difference, completely invisible. Material's default
  scrollbar assumes a light theme and this app has never had one. Now themed
  explicitly in `HamDeckApp`.

I spent an hour chasing a layout bug that did not exist because of the second
one. **Check whether a control is invisible before concluding it is absent.**

⚠️ **Cutting the web to admin-only broke both test tools**, which drive the panel
through a web build: `shoot_panel.py` silently photographed the admin page, and
`panel_e2e.py` reported that no control reached the radio - because it was
pressing keyboard shortcuts at a page that has none. Both point at
`client/build/web-shoot` now, and preflight builds it.

### The Windows drive now asserts what is on the screen
Two false results had to be beaten out of the harness before any of the above
could be believed:

- **It reported "the panel survived being given F13" after selecting *Pause*.**
  Flutter aligns the SELECTED row with the button, so every menu row's absolute
  position shifts with whatever is already chosen, and a fixed coordinate quietly
  picks a different key. `tools/win_read.sh` now OCRs the KEY field and the step
  fails if the wrong key is selected.
- ⚠️ **`qm monitor sendkey f13` is ACCEPTED and delivers nothing.** A probe polling
  `GetAsyncKeyState` inside Windows saw F12 (VK 0x7B) every time and never once
  saw F13 (VK 0x7C). An F13 *press* test through this keyboard could never pass
  however correct the app was, and read as "the PTT is broken". The press test
  now uses F12 - same watcher, same table, only the virtual-key constant differs
  - and F13 remains the crash test.

Also fixed: the drive only checked the simulator on **localhost**, which says
nothing about whether the panel can reach it; one run blamed the panel for a host
that was simply not reachable from Windows. It now runs Test-NetConnection from
the box under test.

### Branding verified in the ARTIFACTS, not the source tree
- Windows: **7 of 7** icon frames from `hamdeck.ico` found inside `hamdeck_panel.exe`.
- Linux: the `.deb` ships **8 hicolor sizes** and the `.desktop` points at them.
- macOS: `AppIcon.icns` inside the `.dmg` renders as the Yagi.
- Web: `favicon.png` and the PWA icons are byte-identical to the brand files.

⚠️ **Open, minor: the macOS `.icns` carries only 16/32/128/256** (`ic04 ic11 ic07 ic13`) -
no 512 or 1024 - so Finder upscales at large icon sizes. `Contents.json` declares all ten
entries and every source PNG is the correct dimension, so `actool` is dropping them for some
other reason. Not chased: no Mac here, and it is cosmetic. ⚠️ PIL reported only three
representations where the real table of contents has four - parse the icns, do not trust
`Image.info['sizes']`.

## Next
1. Rebuild, reinstall on the `clean` snapshot, run `tools/win_drive.sh` — prove
   F13 assigns without crashing and that a press keys the rig.
2. **Cut the web build to admin-only** (his call: "Admin only, no operating") —
   accounts, sessions, lockdown, KILL TRANSMIT, read-only status. No operating
   surface in a browser. NOT STARTED.
3. Code signing — SmartScreen "unknown publisher" is the biggest adoption
   blocker. SignPath Foundation is free for OSS.
4. Considered: private Forgejo origin + push-mirror to public GitHub, with
   self-hosted runners for Linux/Windows CI (macOS must stay on GitHub — no Mac).
   Separate build, not started.

## Standing warnings
- ⚠️ **Check the antenna selection before transmitting.** An earlier parity run
  cycled it, and VFO B's stored frequency is not recoverable.
- The rig is routed REAR/USB, so the hand mic is dead until the panel
  disconnects or `remote-tx/off` is sent.
