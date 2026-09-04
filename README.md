# HamDeck (Go)

A ham radio station host and panel: CAT control, a REST API, and a remote panel —
**Go server, Flutter client**.

⚠️ **This is an experiment running beside a working system, not a replacement.** The station
is on the air with a C++ host and a Qt client. This binds different ports, talks to a
**simulated rig**, and never opens a serial port or an audio codec — the radio is
single-instance hardware and two hosts fighting over it is the one way an experiment costs
something real.

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

Audio (capture, playback, the PCM socket), real serial CAT, the transmit watchdog. Those are
the hard parts and the C++ host earns its keep on them — a comparison that skips them is not a
comparison.
