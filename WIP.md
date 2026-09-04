# HamDeck Go + Flutter — where this stands

Updated 09/04/2026. Read `docs/PORT-FROM-CPP.md` first; it is the checklist this
was built from.

## Live right now

- **Station host**: VM 105 (`192.168.40.64`), `systemd` unit `hamdeck-go`,
  installed at `/opt/hamdeck-go`, credential in `/etc/hamdeck-go/env` (mode 600),
  recordings in `/var/lib/hamdeck-go/recordings`. Version **0.2.0**.
  It is ENABLED, so it comes back after a reboot — the earlier hand-started
  `/tmp/hgo` did not.
- **Radio**: `/dev/ttyRIG` at 38400, USB codec in at 22050 Hz / out at 44100 Hz.
- **Tuner**: TG-XL at `192.168.40.51:9010`.
- **Login**: `admin` / `gotest` on `http://192.168.40.64:5102`. LAN only, no tunnel.

## The gates — run these, do not reason about them

    tools/parity.py http://192.168.40.64:5102 admin gotest
        every C++ route has a Go route, and every Go route answers

    tools/check_audio_roundtrip.sh client/build/linux/x64/release/bundle/hamdeck_panel
        receive AND transmit proved by PITCH, not packet counts

    tools/measure_pitch.py <wav> <expected hz>
        the only check that catches a wrong sample rate

    packaging/build-deb.sh <version>
        refuses to package a binary whose --version disagrees with the filename

⚠️ **Run parity against the STATION, not the simulator.** Three real faults
passed clean on the simulator and failed on the radio: crossed CAT replies, a
parser that required a semicolon the serial transport strips, and a frequency
length off by one.

## What is not done

- Users added through the admin routes live in memory only.
- Installers are unsigned: SmartScreen warns on Windows, and the DMG needs
  right-click → Open on macOS.
- Receive latency is 371 ms.
- The C++ host on VM 105 is stopped. Both cannot run: one process holds the
  serial bridge and the codec.
