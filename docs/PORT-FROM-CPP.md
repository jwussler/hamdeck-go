# Porting HamDeck C++ → Go host + Flutter panel

Walked out of `~/hamdeck-cpp` on 09/04/2026, route by route, from the source
rather than from memory. **This file is the checklist.** Nothing is "done"
because it was written; it is done when the parity gate calls the route and
reads the result back through something that is not the route under test.

⚠️ **The C++ repo already learned these lessons the expensive way.** Where a
route has a note here it is because `src/api.cpp`, `src/tgxl.cpp` or
`docs/internal/CARRYOVER.md` says so in a comment written after something broke.
Port the note with the code.

## Where the two hosts stand

| | C++ host | Go host, today |
|---|---|---|
| generated rig routes | 53 | 3 |
| prefix (parameterised) routes | 23 | 0 (freq/mode/ptt are hand-written) |
| tuner | TGXL over TCP + internal ATU, kept separate | none |
| recording / replay | yes | none |
| admin (users, sessions, lockdown, remote unkey) | yes | none |

## 1. Rig control — the CAT table

Ported as ONE table, not scattered handlers, because the C++ version is one
table and the drift between two hand-written lists is the bug.

| route | CAT | note |
|---|---|---|
| `/api/mode/<m>` | `MD0<code>;` | USB LSB CW AM FM DATA-U |
| `/api/band/<b>` | `MD0<code>;` then `FA<9d>;` | band → centre freq AND the band-plan mode; 160→1.880, 80→3.860, 60→5.3305, 40→7.200, 30→10.130, 20→14.200, 17→18.130, 15→21.300, 12→24.940, 10→28.400, 6→50.125 |
| `/api/freq/set/<hz>` | `FA<9d>;` + `MD0<code>;` | mode follows the band plan: 5.30–5.50 USB, 10.10–10.15 CW, else <10 MHz LSB / ≥10 MHz USB |
| `/api/power/set/<w>` | `PC<3d>;` | ⚠️ clamp: local/trusted caps at 100 W, hard ceiling 200 W |
| `/api/volume/set/<v>` | `AG0<3d>;` | |
| `/api/rf-gain/set/<v>` | `RG0<3d>;` | |
| `/api/cw-speed/set/<n>` | `KS<3d>;` | also `/cw-speed/up`, `/down` |
| `/api/agc/cycle` | `GT0<n>;` | reads Snapshot first, then advances |
| `/api/preamp/on\|off\|cycle` | `PA00;` `PA01;` `PA0<n>;` | |
| `/api/ant/toggle` | `AN0<n>;` | |
| `/api/ant/rx/on\|off\|toggle` | `EX0301031;` / `EX0301030;` | menu write — see §4 |
| `/api/comp/on\|off\|toggle` | `PR02;` / `PR01;` | |
| `/api/mon/on\|off\|toggle` | `ML0001;` / `ML0000;` | |
| `/api/notch/on\|off\|toggle` | `BC01;` / `BC00;` | |
| `/api/rit/clear` | `RC;` | plus `/rit/up`, `/rit/down`, `/rit/toggle` |
| `/api/vfo/swap` | `SV;` | plus `/vfo-copy/a2b`, `/b2a`, `/vfo-lock/*` |
| `/api/quick-split` | `FA;` `VS1;` `VS0;` `ST1;` | a sequence, not one verb |
| `/api/tune` | `AC002;` | ⚠️ the RIG'S INTERNAL ATU — **not** the TGXL |
| `/api/ptt/on\|off\|toggle\|unkey` | `TX1;` / `TX0;` | |
| `/api/cw/stop` | `KY0;` | |
| `/api/memory/recall/<n>` | `MC<3d>;` | |
| `/api/remote-tx/gain/<g>` | `EX010113<3d>;` | RPORT GAIN |
| `/api/ssb-out-level/set/<v>` | `EX010109<3d>;` | |

## 2. The tuner — `/api/tune/tgxl`

TGXL at **192.168.40.51:9010** (from the station config, not invented).

⚠️ **It is a different box from `/api/tune`.** Each names itself in its reply so
a confirmation can never just say "tuning" and leave the operator guessing which
thing is about to key up.

⚠️ **The tuner needs a carrier — that is the whole sequence.** Sending autotune
with the transmitter idle tunes nothing and looks like a dead button:

1. save the current power and mode
2. set 15 W, set CW
3. **connect TCP first**, 3 s connect timeout
4. key the transmitter, settle
5. send `C1|autotune\n`
6. poll `C1|status\n`, read lines carrying `tuning=<0|1>`
7. unkey, then restore the saved power and mode

⚠️ **3 before 4 is deliberate** and the reference host had it the other way
round: keying first puts 15 W into the antenna for the whole 3 s connect timeout
of a tuner that is switched off.

⚠️ **7 must happen on EVERY exit path** — timeout, refused connection, thrown
error, operator stop. A tuner that leaves the rig keyed at 15 W in CW is worse
than one that never tunes.

⚠️ **Completion is "tuning went 1 THEN 0", not "tuning is 0".** The tuner emits
0,1,0 within milliseconds of connecting; a real tune takes 3–15 s. So: `1` arms
the finish; `0` finishes only if `1` was seen AND 2 s have passed; a 1→0 inside
that window is the connect burst — disarm and keep waiting; never seeing `1` at
all gives up at 5 s. The first C++ port used "seen OR elapsed > 2 s", which
reports a completed tune at 2.001 s against a tuner that never started.

`tools/fake_tgxl.py` in the C++ repo is the test instrument — use it, and make it
emit the connect burst.

## 3. The panel — what the Qt client has that the Flutter one does not

S-meter and TX meters (`SMeter.qml`, `TxMeters.qml`), knobs that respond to drag
(`Knob.qml` — ⚠️ every slider in the Qt panel had **zero height** and swallowed
no mouse events for the life of the project, and every geometry check stayed
green, so a control that matters gets a synthetic-drag test), band/ant/AGC/preamp
keys, RIT/XIT, the VFO block, the frequency keypad, the tuner button with its
in-progress state, recording + replay, and the admin page.

## 4. Traps that carry over

- ⚠️ **CAT menu writes need 50 ms between them.** Sent back to back the rig takes
  the first and ignores the rest, silently. Applies to every `EX…` above.
- ⚠️ **Never probe a live rig with a control route.** `/api/health` is the only
  route needing no session.
- ⚠️ **When a read fails, answer `null`.** `/api/remote-tx/status` once reported a
  hardcoded MIC while the radio was already on REAR/USB, so a correct write was
  reported as a failure and the search went to the wrong end of the chain.
- ⚠️ **The transmit watchdog lives next to the radio**, never in the client.
- ⚠️ **Unkeying waits for queued audio** — ask the kernel, never infer from byte
  counts; that estimate is ≈0 in steady state and reads like a real measurement.
- ⚠️ **Mute RX while keyed.** Never feed the operator their own delayed audio.
- ⚠️ **A muted microphone is perfectly formed silence at the right rate.** 1098
  packets went out under a lit ON AIR bar on 09/04/2026. Level, loudly — not a
  packet count.

## Order of work

1. microphone chooser + local monitor + silence alarm  ← the on-air fault
2. the tuner
3. the CAT table above
4. the panel controls to match
5. recording, then admin
