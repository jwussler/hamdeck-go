# HamDeck (Go)

A ham radio station host and panel: CAT control, a REST API, and a remote panel —
**Go server, Flutter client**.

⚠️ **This now runs the station.** It was an experiment beside the C++ host when this file was
written, and that stopped being true on 09/04/2026: the Go host holds `/dev/ttyRIG` and the
USB codec on VM 105, keys the transmitter, drives the TG-XL, and the C++ host is stopped.

**Only one of them can run.** The radio is single-instance hardware — one process holds the
serial bridge and the codec — so starting the C++ host while this one is up gets neither of
them a working radio.

It still talks to a **simulated rig** when `--radio` is empty, which is how everything except
the station itself is tested. ⚠️ Three real faults passed clean on that simulator and failed
on the radio, so the gates below are run against the STATION.

## What it is testing

| | |
|---|---|
| **Can one person keep this alive for ten years?** | Go's compatibility promise, and a build that is `go build` rather than CMake plus vendored C libraries |
| **Can it speak to radios nobody here owns?** | A rig **interface**. The simulator and a serial port are both just a `Rig`; a second model is a table, not a rewrite. The C++ host hardcoded one radio's verbs and that is its ceiling |
| **Can a blind operator use it?** | Flutter ships a real screen-reader semantics layer. This is the clearest open goal in remote radio software and it is why Flutter beat a pure-Go UI here |

## Running it

```
go build ./cmd/hamdeck-host
./hamdeck-host --hash-password          # prompts, prints the env line
HAMDECK_ADMIN_HASH=pbkdf2:... ./hamdeck-host --panel client/build/web
```

⚠️ It starts with **no users** rather than a default login, and says so. A shipped credential
is a credential everybody has.

## Layout

- `cmd/hamdeck-host` — the server. Serves the API *and* the panel, so "install the server" is
  the whole setup and a browser is a first-class client.
- `cmd/hamdeck-panel` — a second panel in pure Go (Gio), kept as a comparison. It works, it is
  half the download, and it has no accessibility layer.
- `client/` — the Flutter panel: web, Linux, and Windows/macOS from the same source.
- `internal/rig` — the interface the whole point rests on.

## Not done yet

⚠️ This list used to name audio, serial CAT and the transmit watchdog. All three are done and
on the air; what is left is:

- **Users added through the admin routes live in memory only** — an account added on the panel
  is gone at the next restart. The station's own admin comes from `/etc/hamdeck-go/env`, which
  does survive.
- **The installers are unsigned** — SmartScreen warns on Windows, and the DMG needs
  right-click → Open on macOS. This is the biggest adoption blocker left.
- **371 ms of receive latency**, against the C++ host's shorter buffer.
- **The transmit/receive switching time has never been measured.**
- **LAN only.** There is no path in from outside the house yet.
