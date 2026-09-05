# The checks

**`preflight.sh` runs everything below and must pass before a binary is cut.**
`preflight.sh quick` skips the slow ones.

Each of these is a gate: it **refuses**, it does not remind. And each has been made to
**fail on demand** — a check that has only ever passed is untested.

---

## Before anything is built

| | |
|---|---|
| `check_branding.py` | The HamDeck mark is on the app, the installer, the shortcuts and the Linux launcher, and the window title is not the build-target name. ⚠️ Every build up to 09/05/2026 shipped **Flutter's own logo** as the Windows app icon, the installer had no icon at all, and the `.desktop` named an icon nothing installed. Runs in CI too. |

## After the panel is built

| | |
|---|---|
| `check_web_is_admin_only.py` | Greps the **shipped `main.dart.js`** for strings that exist only on the operating surface, and for strings that must be on the admin page (an empty bundle would otherwise pass). ⚠️ It checks **both encodings** — one em dash makes a Dart string UTF-16 in the snapshot and an ASCII grep then calls a present feature missing. Runs in CI too. |
| `shoot_panel.py` | Photographs the panel in every state and width that matters. ⚠️ Builds its **own** bundle with `--dart-define=HAMDECK_SHOOT=true`; the shipped web build is the admin page and has no operating surface to photograph. |
| `panel_e2e.py` | Proves the keyboard shortcuts actually reach the radio, not just that the panel draws. Same bundle as above. |

## The boundaries

| | |
|---|---|
| `check_auth.py` | Every route needs a session, and every gated route still answers one. |
| `parity.py` | Every C++ route has a Go route, and every Go route answers. ⚠️ **Read-only by default**; `--allow-control` refuses unless `/api/health` reports a *simulated* rig. It once drove control routes into the live radio and destroyed VFO B's stored frequency. |

## Audio

| | |
|---|---|
| `measure_pitch.py` | The one question no counter can answer: does the audio out of the speaker have the same **pitch** the host sent? A client playing a 22050 Hz stream at 44100 passes every other check here — right packet count, right byte count, full level bar — and sounds an octave high. |
| `check_audio_roundtrip.sh` | Receive and transmit paths carry audio end to end. |

---

# Driving the Windows box (VM 109)

`win_test.sh <installer.exe>` installs on the clean baseline and proves the app starts.
`win_drive.sh [outdir]` then **uses** it: logs in, opens SETUP, assigns F13, presses a key.
`win_baseline.sh reset` rolls the VM back to `clean` — a Proxmox snapshot, not an in-guest
tool, so nothing inside the machine under test can interfere with it.

Installing is not using. Both of the worst bugs of 09/04–05 — the crash on choosing a PTT
key, and an app that could not launch on a clean machine — were only visible past "it built".

### ⚠️ The harness lied five different ways. Read this before trusting a green run.

- **Every click replayed the PREVIOUS call's coordinates.** `win_click.sh` wrote its actions
  to a file on the VM and **the write silently did not happen**, so the task read the old
  file. Two different clicks both reported `clicked 383,320`. Actions are a task **argument**
  now and carry a **nonce** the result must echo back.
- **`qm monitor mouse_move` is RELATIVE**, even against this guest's absolute HID tablet,
  which accumulates the deltas **unbounded** — one big negative "home" move put the pointer
  past −40000 where nothing recovered it. Pointing is done **inside the session**
  (`win_ui.ps1`, SetCursorPos, pointer read back). The keyboard stays on the hypervisor.
- **`sendkey f13` is accepted and delivers nothing.** A probe polling `GetAsyncKeyState`
  inside Windows saw F12 (VK 0x7B) every time and F13 (VK 0x7C) never. F13 is the *crash*
  test; the *press* test uses F12 — same watcher, same table, only the constant differs.
- **Counting requests is not checking one worked.** "The host saw a login" counted
  `POST /api/auth/login`, which the host logs for a **refused** password too.
- **A measurement is only as good as its baseline.** The password-box ink threshold was first
  set from a box that had not been cleared, so "eight characters" was really sixteen.

### The pieces

| | |
|---|---|
| `win_launch.ps1` | Starts the panel in the operator's session. Session 0 has no desktop; a windowed app started there runs where nobody can see it. Verifies its own task registration. |
| `win_ui.ps1` / `win_ui_run.ps1` | The pointer, inside the session, with the nonce. |
| `win_click.sh` | `win_click.sh "click 650,314"` — refuses a result that is not this call's. |
| `win_sendtext.sh` | Types a string. **One connection, paced** — an ssh per key took 25 s and Windows raised the Start menu mid-password; all at once drops the string entirely. |
| `win_read.sh` | OCRs a box on screen, so a check can assert what is **actually** there. |
| `win_find.sh` | Finds text and returns where it is. ⚠️ Menu rows move with the current selection, so they are **found, not calculated**; and OCR reads this UI's digits badly (`F1i4` for F14), so anchor on wording — "footswitch" is only on the F13 row. |
| `win_ink.sh` | Counts ink in a box — for the password field, which has nothing to read back. |
