# The Go host, audited — 09/05/2026

Read-only audit of the **server side** (`cmd/hamdeck-host` + `internal/`), written
before any rework so the rework is built from evidence rather than from whatever
was most recently annoying. Nothing here was changed to produce it.

The client (`client/`, Flutter) is deliberately **out of scope**.

---

## The shape

| | lines |
|---|---|
| `internal/api` (4 files) | **1,900** |
| `internal/audio` (5 files) | 1,239 |
| `internal/rig` (3 files) | 905 |
| `cmd/hamdeck-host` (2 files) | 632 |
| `internal/auth` (3 files) | 603 |
| `internal/tuner` | 236 |
| `internal/catproxy` | 208 |
| `cmd/hamdeck-panel` (Gio) | 490 |
| `cmd/txprobe` | 117 |
| **source total** | **6,330** |
| **tests total** | **552** |

6,330 lines is *small*. A rewrite is genuinely tractable — this is not a
year-long project, and that matters for the decision.

**Tests exist for `audio`, `auth`, `catproxy` only.** `api` (1,900 lines),
`rig` (905) and `tuner` (236) have **no test files at all** — 3,041 lines, just
under half the host, with no unit coverage. What protects them today is the
end-to-end gates in `tools/` (`check_auth.py`, `parity.py`, `panel_e2e.py`),
which need a running host and a panel.

---

## Findings, worst first

### 1. Authorisation is applied two different ways ⚠️

- **13** routes are wrapped in the `guard()` helper.
- **18** routes hand-roll `if !s.authed(r) { 401 }` inside the handler body.

This is the most security-critical decision in the host and there is no single
place that makes it. It is correct *today* only because `tools/check_auth.py`
walks every registered route and fails if one answers without a session. Remove
that gate and the next route added is a coin flip.

**A rework should make it impossible to register an unguarded route**, rather
than checking afterwards that nobody did.

### 2. The `Rig` interface does not describe the rig

`rig.Rig` has five methods. `rig.Serial` has about twenty. Everything
interesting is reached by **runtime type assertion** — seven of them, in four
files:

```
internal/api/rigroutes.go:118   s.Rig.(catRig)
internal/api/rigroutes.go:630   s.Rig.(catRig)
internal/api/api.go:481         s.Rig.(interface{ SetMuted(bool) error })
internal/api/api.go:496         s.Rig.(interface{ SetMuted(bool) error })   ← same shape, twice
cmd/hamdeck-host/main.go:285    r.(catproxy.Rig)
cmd/hamdeck-host/main.go:363    r.(*rig.Serial)
cmd/hamdeck-host/main.go:382    t.r.(interface{ Send(string) error })
```

Two of those are the *same* anonymous interface declared twice inline. Each
assertion is a capability that silently disappears against the simulator, which
is why `main.go` needs the `asRig2` / `asTuner` / `tunerRig` adapters — three
different ways to narrow one object, one of which exists solely to stop a **typed
nil in an interface** taking the host down (its comment says so).

### 3. `api.Server` is a 14-field bag of optionals

`Audio`, `Tx`, `TxRec`, `Rec`, `Tuner`, `Rig2`, `Lock`, `Flags`, `PanelDir`,
`AltPanelDir`… most may be nil, and `api.go` contains **16 `== nil` checks** to
cope. It is constructed **twice** in `main.go` — once for the control listener,
once for the dashboard — with the field list duplicated, so the two can drift.

`Rig` and `Rig2` as field names is the smell stated plainly.

### 4. Deferred cleanup in `main()` is dead code

```go
defer cp.Close()      // cat proxy
defer txRec.Close()   // transmit recorder
...
if err := pub.ListenAndServe(); err != nil { log.Fatalf(...) }
```

`ListenAndServe` blocks; when it returns, `log.Fatalf` exits the process. **The
deferred closes can never run.** There is no signal handling and no graceful
shutdown anywhere in the host — `systemctl restart` is a `SIGTERM` to a process
that has no idea what that means.

### 5. `main()` does eight jobs

409 lines: account CLI dispatch (before flag parsing), flag definitions, three
diagnostic modes (`--audio-list`, `--audio-probe`, `--audio-ladder`), rig
opening, audio opening, recorder, cat proxy, tuner, two HTTP servers, and the
three interface adapters. All 14 `log.Fatal` calls in the whole repo are here —
which is *good* discipline (the libraries degrade, the wiring dies loudly), but
it means the wiring is untestable as written.

### 6. Nothing is supervised except, as of today, audio capture

Receive capture lost its device twice in two days and never reopened; that is
fixed now (`internal/audio/stream.go`, `supervise`). **But it was fixed as a
special case.** The serial rig, the cat proxy and the tuner have no equivalent —
if `/dev/ttyRIG` throws the same class of error, the same silent failure is
available to it. Supervision belongs as a pattern the host applies to every
device it owns.

### 7. Deploys are `cp` and a `.bak`

`/opt/hamdeck-go/bin/` currently holds **ten** stacked backups from one night:
`0.4.0`, `0.4.1`, `0.4.2`, `0.5.0`, `0.5.1`, `0.6.0`, `0.6.1`, `0.7.0`, `0.7.2`,
`0.7.3`. There is no deploy command, no rollback command, and no health check
after restart — the check is a human reading the journal.

### 8. Small stuff, real

- **The header comment on `main.go` is a lie now.** It says "an experiment
  running beside a working C++ host… never opens the serial port or the codec".
  It *is* the production host, on `/dev/ttyRIG` and the codec. First thing a
  reader sees.
- `var pttTimeout = 180 * time.Second` with a package-level `SetPTTTimeout()` —
  global mutable state for the transmit watchdog, of all things.
- **`cmd/hamdeck-panel` (490 lines, Gio) is abandoned.** CI only type-checks it
  (`go build -o /dev/null`), and its presence is why the host's own vet step
  cannot use `./...` (Gio needs X11/Wayland headers). It lost to Flutter.
- `cmd/txprobe` (117 lines) is referenced nowhere but itself. Small and possibly
  still useful as an instrument, but undocumented.

---

## What is genuinely good, and should survive

Say this plainly so a rewrite does not throw it away:

- **The CAT table in `rigroutes.go` is one table, not scattered handlers**, with
  the band plan riding along with every frequency change. The comment explains
  why (`changing band without changing mode lands you on 40 m in USB`). Keep the
  shape.
- **`auth` is file-backed, atomic, 0600, PBKDF2, reloads live, and refuses to
  remove the last admin.** It has real tests. Leave it alone.
- **The poller yields the serial line to operator commands** and decimates the
  rarely-changing reads. That is hard-won and not obvious.
- **Failed reads leave the previous value and let it go stale** rather than
  inventing one, and the age travels with the reading.
- **The stale-value and silence rules in `audio`**: `Peak()` decays so it cannot
  call a dead receiver a live band.
- **The gates in `tools/`** are the reason the host is trustworthy at all.

---

## What I would change, and what is yours to decide

**My recommendation is not "rewrite it all".** At 6,330 lines the risk is not
effort, it is losing the hard-won rules above, which live in comments rather than
tests. I would do it in this order:

1. **One way to authorise.** Registration that cannot produce an unguarded route.
   *Gate:* `check_auth.py` keeps passing, plus a unit test that a route
   registered without a policy fails to compile or panics at startup.
2. **A rig contract that says what a rig can do**, with capability checks instead
   of seven runtime assertions. The simulator then implements the same contract
   honestly rather than being missing methods.
3. **Split the god-`main`**: wiring in one testable place, diagnostics
   (`--audio-list` / `--audio-probe` / `--audio-ladder`) into a subcommand.
4. **Supervision as a pattern**, applied to serial and the cat proxy the way it
   now applies to capture. Plus real shutdown on `SIGTERM`.
5. **A deploy script with rollback and a post-restart health gate**, replacing
   `cp` + `.bak`.
6. **Delete the Gio panel.** 490 lines and a CI constraint for an experiment that
   ended.

### Open questions — these change the design and they are yours

1. **Is the API surface allowed to shrink?** 137 routes exist for C++ parity, and
   `parity.py` enforces it. I cannot tell from here which routes your Stream Deck,
   the Wavelog pusher, or the phone client actually call. If dead routes may go,
   this is a much smaller job.
2. **Should audio and rig control be one process or two?** Tonight a codec fault
   could not take rig control down only because the failure happened to be
   contained. Splitting them makes that structural — at the cost of a second
   service to run and deploy.
3. **How much downtime is acceptable?** Built alongside on a test rig and cut
   over, or changed in place a piece at a time?
