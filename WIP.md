# HamDeck Go + Flutter — where this stands

Updated 09/04/2026, 6:30 pm. Read `docs/PORT-FROM-CPP.md` first; it is the
checklist this was built from.

## Live right now

- **Station host**: VM 105 (`192.168.40.64`), `systemd` unit `hamdeck-go`,
  installed at `/opt/hamdeck-go`, credential in `/etc/hamdeck-go/env` (mode 600),
  recordings in `/var/lib/hamdeck-go/recordings`. Version **0.5.0**.
  ENABLED, so it comes back after a reboot.
- **Panel**: served by the host itself at `/` from `/opt/hamdeck-go/panel`.
  The previous build is kept beside it as `panel.old` — swap the two
  directories to roll back, no rebuild needed. The 0.4.0 host binary is kept as
  `bin/hamdeck-host.0.4.0.bak`.
- **Radio**: `/dev/ttyRIG` at 38400, USB codec in at 22050 Hz / out at 44100 Hz.
- **Tuner**: TG-XL at `192.168.40.51:9010`. **CAT proxy**: 127.0.0.1:4532.
- **The address**: **`https://radio.wa0o.com`** — the station's only URL. Caddy
  on .60 proxies it to 192.168.40.64:5102 with the real wildcard cert. LAN/VPN
  only, no tunnel. Login: the account in `/etc/hamdeck-go/users.json`.

⚠️ **ONE NAME. Moving the station means editing that `reverse_proxy` line, never
adding a hostname.** `radio.wa0o.com` had been left pointing at the stopped C++
host on :5002 — answering 502 — while the working station sat behind
`radio-go.wa0o.com`, a name nobody asked for. Both `radio-go` and `radio-next`
are deleted. Rollback to the C++ host is `:5002` on the same line.

⚠️ **The panel implies https and takes no port.** `radio.wa0o.com` is the whole
address; the port lives under ADVANCED, blank meaning standard. Defaulting to
http is not merely untidy — getUserMedia is refused on a page that is not a
secure context, so a panel reached over http can receive audio and can never
transmit it, which presents as a broken microphone and is really a URL.
`client/test/base_url_test.dart` holds the eight cases.

⚠️ **The service unit in `packaging/` IS the one the station runs** — copied to
`/etc/systemd/system/hamdeck-go.service`, verified byte-identical. They had
already drifted once: the box had `--cat-proxy-port 4532` and the repo did not,
so a reinstall from the .deb would have silently removed the CAT proxy.

## The gates — run these, do not reason about them

    HAMDECK_PASSWORD=... tools/check_auth.py https://radio.wa0o.com <user>
        every route needs a session except health and the login pair.
        The route list comes from the HOST, so a route added tomorrow is
        checked tomorrow. Safe against the station: every call is made
        WITHOUT a session, so a working route does nothing and answers 401.

    HAMDECK_PASSWORD=... tools/parity.py https://radio.wa0o.com <user>
        every C++ route has a Go route. READ-ONLY by default.

    tools/check_audio_roundtrip.sh client/build/linux/x64/release/bundle/hamdeck_panel
        receive AND transmit proved by PITCH, not packet counts

    packaging/build-deb.sh <version>
        refuses to package a binary whose --version disagrees with the filename

⚠️ **`tools/parity.py --allow-control` is REFUSED against a real radio** and that
is structural — it asks `/api/health` what the rig is, not what the address is,
because "localhost" is a real radio to anybody running it on the station box.
It earned that on 09/04/2026: run against the live station it sent preamp on,
notch on, monitor on, VFO lock on, split on, the filter to wide, cycled the
ANTENNA and the AGC, selected VFO B, and copied VFO A over VFO B — destroying
the frequency parked there. "Safe" had been defined as "does not key the
transmitter", which is the wrong line. Never probe a live rig with a control
route.

⚠️ **Run everything against the STATION, not the simulator.** Three real faults
passed clean on the simulator: crossed CAT replies, a parser that required a
semicolon the serial transport strips, and a frequency length off by one.

⚠️ **`.last_build_id` is NOT a staleness marker.** A stale panel and a freshly
rebuilt one carried the *same* id, so comparing it "proved" the station was up
to date when it was four hours behind. Grep the built `main.dart.js` for a
string only the new code has — that check can tell working from broken.

## Accounts — the way back in

    hamdeck-host users set <name>       create, or reset a password
    hamdeck-host users list | remove | grant <name> tx | revoke <name> tx

⚠️ **`/etc/hamdeck-go/users.json` is the only place an account exists.** No
username in the source, no hash in an environment variable — `HAMDECK_ADMIN_HASH`
and `--hash-password` are deleted, not deprecated, and `/etc/hamdeck-go/env` is
shredded. This was a rewrite of `internal/auth`, not a patch: three mechanisms
that had to agree were about to become four.

⚠️ **A reset reaches the RUNNING host within about three seconds** — the file's
mtime is watched — so recovering a login never means restarting the station and
dropping CAT, the receiver and anything on the air.

⚠️ **`sudo hamdeck-host users set` keeps the file's existing owner.** The service
runs as `ubuntu`; a fresh `root:root 0600` file would leave the host unable to
read its own accounts at the next restart — a password reset that takes the
station down, found hours later. Proved on this box: the file stays `ubuntu:root
0600` and the service user can read it.

⚠️ **The password is never an argument** — not to the CLI, and no longer to
`tools/check_auth.py` or `tools/parity.py`, which take `HAMDECK_PASSWORD` from
the environment or prompt. An argument is in the shell history and visible in
`ps` to everyone on the box.

## Done 09/04/2026 evening

- **The panel the station serves is the panel in git.** It had been four hours
  behind: keyboard operation, the announcements and the link/jitter pill were
  committed but never built or deployed. Rebuilt, deployed, and photographed
  logged in against the live rig (40 m, S9, link 1 ms).
- **Nothing answers without a session.** Eleven routes were replying 200 to
  anyone who could reach the port — what hardware the station has, whether
  transmit was locked down, whether it was recording, the power ceilings, the
  host flags, and the whole route inventory. Gated at registration; open list is
  `/api/health` plus login/logout/status. `tools/check_auth.py` is the gate, and
  it was proved able to FAIL by re-opening `/api/remote/status` and watching it
  get caught.
- **Space is documented as what it does** — a toggle, not hold-to-talk. Over a
  network a lost key-up leaves the carrier up; Escape and the watchdog are the
  stops.
- **README and `serial.go`** no longer describe a read-only experiment that
  never opens a serial port. It runs the station; the C++ host is stopped.
- **Packages rebuilt at 0.5.0**, the stale 0.2.0 pair deleted. Payload checked:
  the keyboard work and both audio plugins are inside the panel .deb.

## What is not done

- Installers are unsigned: SmartScreen warns on Windows, and the DMG needs
  right-click → Open on macOS. **The biggest adoption blocker left.**
- Receive latency is 371 ms.
- Transmit/receive switching time has never been measured.
- LAN only — no path in from outside the house.
- ⚠️ **Left changed on the rig by the parity run and NOT restorable**: VFO B's
  stored frequency (overwritten with VFO A's), and whatever the antenna, AGC,
  preamp, notch, monitor and filter width were before they were cycled. VFO A,
  LSB, split off and lock off were put back with Joe's say-so; the rest he has
  to eyeball. Check the ANTENNA before transmitting.
