// Package api is the HTTP surface.
//
// ⚠️ TWO LISTENERS, AND THE SPLIT IS A SECURITY BOUNDARY, NOT TIDINESS. The
// control listener binds loopback and takes no session - it is for a Stream Deck
// or a script ON the box. The dashboard listener faces the network and requires
// one for everything except health. The C++ host arrived at this the hard way:
// /api/status and the receive audio were once anonymous, so anyone who could
// reach the dashboard could watch the frequency and listen to the receiver.
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/jwussler/hamdeck-go/internal/audio"
	"github.com/jwussler/hamdeck-go/internal/auth"
	"github.com/jwussler/hamdeck-go/internal/rig"
)

type Server struct {
	Rig     rig.Rig
	Auth    *auth.Service
	Version string
	Control bool // loopback, no session
	// Where a built panel lives. Empty = API only.
	PanelDir string
	// ⚠️ A SECOND PANEL, SERVED AT /alt/, SO THE TWO CAN BE COMPARED AGAINST THE
	// SAME HOST AND THE SAME RIG. Judging two clients against different backends
	// would measure the backends.
	AltPanelDir string
	// The receiver, fanned out to whoever is listening.
	Audio *audio.Stream
	// The transmitter's audio, and the rig it routes into.
	Tx *audio.TxSink
	// ⚠️ A TEST INSTRUMENT, set only by --tx-record. When it is set the transmit
	// socket works with no sound card at all, which is what lets a client's
	// transmit path be proved on a machine that has no radio attached.
	TxRec *audio.TxRecorder
	// The receive recorder, or nil when the host has no audio.
	Rec *audio.Recorder

	// Transmit lockdown, enforced next to the radio; see admin.go.
	Lock *Lockdown

	// Settings the host remembers on the panel's behalf; see hostflags.go.
	Flags *hostFlags

	// Every pattern Handler() registered, for the policy test.
	routes []string

	// The antenna tuner, or nil when the host has none.
	Tuner interface {
		Configured() bool
		Describe() string
		Active() bool
		Message() string
		Tune() error
		Stop()
	}
}

// routeMux records every pattern registered.
//
// ⚠️ SO THE HOST CAN BE ASKED WHAT IT SERVES, rather than a script guessing from
// the source with regular expressions. The parity checker was reporting routes
// as missing because it could not see one particular Go literal form - a
// checklist that cries wolf stops being read, and this removes the guessing
// entirely: the answer comes from the same registration the server actually uses.
// ⚠️ THE ServeMux IS A NAMED FIELD, NOT EMBEDDED, AND THAT IS THE WHOLE POINT.
// Embedded, http.ServeMux.HandleFunc is PROMOTED - so deleting the wrapper below
// did not remove `mux.HandleFunc(...)`, it silently redirected every one of them
// to the raw mux: no policy, no path recorded, and it compiled cleanly. The
// unguarded routes would have been found by check_auth.py and the missing paths
// by parity.py, but only after the fact. Named, the compiler refuses instead.
type routeMux struct {
	mux   *http.ServeMux
	paths *[]string
	s     *Server
}

// access says WHO MAY CALL A ROUTE, and every registration states one.
//
// ⚠️ THIS REPLACES THREE DIFFERENT WAYS OF ANSWERING THE SAME QUESTION. Thirteen
// routes were wrapped in guard(), eighteen hand-rolled `if !s.authed(r)` inside
// the handler body, and admin.go had a third wrapper that decided admin-ness by
// URL PREFIX - so an admin route registered anywhere but /api/admin/ would
// silently have got only a session check. Authorisation is the most
// security-critical decision this host makes and there was no single place that
// made it; it was correct only because tools/check_auth.py walks every route
// afterwards and fails if one answers without a session.
//
// ⚠️ AND routeMux.HandleFunc IS GONE, deliberately. While it existed a route
// could still be registered without saying who may call it, and "remember to
// wrap it" is a rule rather than a gate. Now the only way in takes a policy, so
// forgetting is not expressible.
type access int

const (
	// session: any logged-in user.
	session access = iota
	// adminOnly: a logged-in user with the admin flag. By POLICY, not by the
	// shape of the URL.
	adminOnly
	// open: deliberately reachable with no session. Every use is justified at
	// its call site - there are only three, and each is a decision.
	open
)

// route registers a handler behind a stated policy. This is the only way to
// register anything.
func (m routeMux) route(pattern string, who access, h http.HandlerFunc) {
	*m.paths = append(*m.paths, pattern)
	switch who {
	case open:
		m.mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			h(w, r)
		})
	case adminOnly:
		m.mux.HandleFunc(pattern, m.s.guardAdmin(h))
	default:
		m.mux.HandleFunc(pattern, m.s.guard(h))
	}
}

// routeWho is route() for handlers that need to know WHICH account is calling -
// the admin routes, which name the user in what they do and refuse to let one
// remove itself.
func (m routeMux) routeWho(pattern string, who access, h func(http.ResponseWriter, *http.Request, string)) {
	m.route(pattern, who, func(w http.ResponseWriter, r *http.Request) {
		h(w, r, m.s.Auth.Who(token(r)))
	})
}

// mayTransmit answers the one question every keying path has to ask.
//
// ⚠️ TWO SEPARATE REFUSALS, NAMED SEPARATELY. "Locked down" and "your account
// cannot transmit" are different problems with different fixes, and folding them
// into one message sends somebody to the wrong person for help.
func (s *Server) mayTransmit(r *http.Request) (bool, string) {
	if s.Lock != nil && s.Lock.On() {
		return false, "transmit is locked down: " + s.Lock.Reason()
	}
	if !s.Auth.CanTransmit(token(r)) {
		return false, "this account can listen but not transmit"
	}
	return true, ""
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// ⚠️ THE BROWSER IS A FIRST-CLASS CLIENT HERE, which the C++ host never had to
// think about. A Flutter web build is served from somewhere else during
// development, so it is a cross-origin caller - and the credentials it sends are
// a session cookie, so this cannot be "*". It echoes the caller's origin and
// allows credentials, which is the only combination browsers accept.
func cors(w http.ResponseWriter, r *http.Request) {
	if origin := r.Header.Get("Origin"); origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Vary", "Origin")
	}
}

// guard makes a handler need a live session.
//
// ⚠️ MEASURED, NOT REASONED ABOUT. Eleven routes on the dashboard listener were
// answering 200 with no credential at all - what hardware the station has
// (/api/remote/status), whether transmit is locked down, whether it is
// recording, its power ceilings, and the whole route inventory. None of them
// changes the radio, which is exactly why they were missed: each one reads
// harmless on its own, and together they are a survey of somebody's station
// answered to anyone who can reach the port.
//
// ⚠️ TWO ROUTES STAY OPEN ON PURPOSE: /api/health, which is how you ask "is the
// host up" without holding a credential, and /api/auth/login and its status.
// Everything else is gated at the point of REGISTRATION rather than by a path
// prefix - a prefix gate that stops matching after a rename fails OPEN.
// guardAdmin is guard() plus the admin flag.
//
// ⚠️ IT DOES NOT LOOK AT THE URL. The wrapper this replaces checked
// strings.HasPrefix(path, "/api/admin/"), which meant the policy lived in the
// route's NAME - move an admin route and it quietly becomes a user route.
func (s *Server) guardAdmin(fn http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		tok := token(r)
		if s.Auth.Who(tok) == "" {
			writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
			return
		}
		if !s.Auth.IsAdmin(tok) {
			writeJSON(w, 403, map[string]string{"status": "error",
				"message": "that needs an administrator account"})
			return
		}
		fn(w, r)
	}
}

func (s *Server) guard(fn http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ THIS CHECK IS THE WHOLE FUNCTION. A scripted removal of the
		// now-redundant inline `if !s.authed(r)` blocks stripped it out of
		// guard() too - the body matched the same pattern - and left a wrapper
		// that set CORS headers and called the handler. 121 routes answered
		// without a session and the host still built, vetted and served
		// perfectly. tools/check_auth.py is what noticed.
		if !s.authed(r) {
			writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
			return
		}
		fn(w, r)
	}
}

func (s *Server) authed(r *http.Request) bool {
	if s.Control {
		return true // loopback listener: the bind IS the security model
	}
	if c, err := r.Cookie("hamdeck_session"); err == nil && s.Auth.Valid(c.Value) {
		return true
	}
	// The audio socket cannot carry a cookie in every client, so a token is
	// accepted in the query the same way the C++ host does it.
	return s.Auth.Valid(r.URL.Query().Get("token"))
}

// Routes is every pattern this server registered, available after Handler().
func (s *Server) Routes() []string { return append([]string(nil), s.routes...) }

func (s *Server) Handler() http.Handler {
	real := http.NewServeMux()
	var registered []string
	mux := routeMux{mux: real, paths: &registered, s: s}
	// ⚠️ Kept on the Server so a TEST can ask what was actually registered.
	// A test carrying its own copy of the route list would pass while the server
	// served something else entirely - which is the failure tools/parity.py was
	// written for after a checklist and the behaviour disagreed in silence.
	defer func() { s.routes = append([]string(nil), registered...) }()

	// Health takes no session on purpose: it is how you ask "is the host up"
	// without holding a credential, and it says nothing about the band.
	// ⚠️ open: it is how you ask "is the host up" without holding a credential,
	// and it says nothing about the band.
	mux.route("/api/health", open, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, map[string]any{
			"status": "ok", "service": "HamDeck API (Go)", "version": s.Version,
			"rig": s.Rig.Describe(), "rig_connected": s.Rig.Snapshot().Connected,
			"auth_configured": s.Auth.Configured(),
		})
	})

	// ⚠️ open, necessarily: this IS the door. A regex conversion made it require a
	// session once, which is a bootstrap deadlock - you would need to be logged
	// in to log in - and it fails CLOSED, so every client simply stops working.
	mux.route("/api/auth/login", open, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if r.Method == http.MethodOptions {
			return
		}
		var body struct{ Username, Password string }
		json.NewDecoder(r.Body).Decode(&body)
		tok := s.Auth.Login(body.Username, body.Password)
		if tok == "" {
			// ⚠️ Deliberately slow and deliberately vague. Same message whether
			// the user exists or the password was wrong.
			time.Sleep(300 * time.Millisecond)
			writeJSON(w, 401, map[string]string{"status": "error", "message": "Invalid credentials"})
			return
		}
		http.SetCookie(w, &http.Cookie{
			Name: "hamdeck_session", Value: tok, Path: "/",
			HttpOnly: true, SameSite: http.SameSiteLaxMode,
		})
		writeJSON(w, 200, map[string]string{"status": "ok", "token": tok})
	})

	mux.route("/api/status", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, s.Rig.Snapshot())
	})

	// ── The rest of the C++ host's surface ──────────────────────────────────
	//
	// ⚠️ THE QT CLIENT CALLS NINETEEN ROUTES AND TWO SOCKETS, and it fails in
	// different ways for each missing one - a 404 on /api/meters is a dead
	// S-meter, a 404 on /api/status/full is every receiver toggle stuck off. The
	// point of matching this surface is that the EXISTING signed, packaged apps
	// on Windows, macOS, Linux and iOS connect to this host with nothing
	// rebuilt. Where this host genuinely cannot do a thing yet, it answers
	// honestly rather than 404ing: a client that gets "available: false" shows a
	// disabled control, and one that gets a 404 shows an error.
	mux.route("/api/meters", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		snap := s.Rig.Snapshot()
		// ⚠️ EVERY FIELD HERE IS DERIVED, NONE IS A PLACEHOLDER. This route used
		// to answer power:0, power_pct:0, swr_ratio:1.0, s_meter_db:0 and an
		// empty s_unit as literals - a perfect SWR and a dead power meter
		// reported with the same confidence as the readings that were real. That
		// is the exact fault the C++ host wrote down after a status route
		// invented three fields and sent an evening of debugging to the wrong end
		// of the chain. Each of these now comes off the radio through its own
		// calibration curve, and the curves are not interchangeable.
		db := rig.SMeterDb(snap.SMeterRaw)
		writeJSON(w, 200, map[string]any{
			"status": "ok",
			// The raw readings, as the radio gave them.
			"s_meter": snap.SMeterRaw, "swr": snap.SWRRaw,
			"alc": snap.ALCRaw, "power": snap.PowerMtrRaw,
			// ⚠️ The derived values carry their unit IN THE NAME, so no client can
			// mistake a percentage for watts - the C++ host's rule, kept.
			"s_meter_db": db,
			"s_unit":     rig.SUnit(db),
			"swr_ratio":  rig.SWRRatio(snap.SWRRaw),
			"alc_pct":    rig.ALCPercent(snap.ALCRaw),
			"power_pct":  rig.PowerMeterPercent(snap.PowerMtrRaw),
			// ⚠️ The transmit meters mean nothing while receiving, and a client
			// that draws them anyway shows a flat SWR of 1.0 as though it had
			// been measured. Say which readings are live.
			"tx": snap.TX,
		})
	})

	mux.route("/api/meters/scale", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ NO CALIBRATION IS SHIPPED, AND THAT IS SAID OUT LOUD. The C++ host
		// carries hamlib's table and states in the payload that it was not
		// measured on this station; inventing one here would put invented S-units
		// on a report an operator passes to another human. An empty tick list
		// makes the client draw an UNLABELLED scale, which is the honest picture.
		writeJSON(w, 200, map[string]any{
			"status": "ok", "raw_max": 255, "s9_raw": 160,
			"source":      "not calibrated on this host - the meter face is unlabelled on purpose",
			"calibration": []any{}, "ticks": []any{},
		})
	})

	mux.route("/api/status/full", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		snap := s.Rig.Snapshot()
		// ⚠️ Only what this host actually reads. Every field here is polled from
		// the radio or absent; none is a plausible default. A receiver toggle
		// that reports "off" because nobody asked the rig is a confident wrong
		// answer about the operator's own station.
		writeJSON(w, 200, map[string]any{
			"freq_b": snap.FreqB, "agc": "", "ant": 0,
		})
	})

	mux.route("/api/backend", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		out := map[string]any{"status": "ok", "cat": s.Rig.Describe(), "simulated": false}
		if s.Audio != nil {
			out["rx_audio"] = s.Audio.Describe()
			out["rx_peak"] = s.Audio.Peak()
		}
		if s.Tx != nil {
			written, dropped := s.Tx.Stats()
			out["tx_audio"] = s.Tx.Describe()
			out["tx_peak"] = s.Tx.Peak()
			out["tx_accepted"] = written
			out["tx_dropped"] = dropped
		}
		writeJSON(w, 200, out)
	})

	// ⚠️ ANSWERED HONESTLY RATHER THAN 404ed. This host has no amplifier, no
	// recorder and no per-user profiles yet; a client that asks gets "not
	// available here" and disables the control, instead of showing an error for
	// a feature that was never claimed.
	// ── Recording ────────────────────────────────────────────────────────────
	//
	// ⚠️ THE REPLY IS DERIVED FROM WHAT HAPPENED, NOT FROM THE ROUTE EXISTING.
	// The reference implementation answered {"status":"ok","recording":true}
	// from start while its recorder had failed to open the file. Here every
	// answer comes from the recorder's own state after the attempt.
	recStatus := func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if s.Rec == nil {
			writeJSON(w, 200, map[string]any{"status": "ok", "available": false,
				"recording": false,
				"message":   "this host has no receive audio, so nothing to record"})
			return
		}
		out := s.Rec.Status()
		out["status"] = "ok"
		writeJSON(w, 200, out)
	}
	mux.route("/api/record/status", session, recStatus)

	recAct := func(action string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			if s.Rec == nil {
				writeJSON(w, 503, map[string]any{"status": "error", "available": false,
					"message": "this host has no receive audio, so nothing to record"})
				return
			}
			var name string
			var err error
			did := action
			switch action {
			case "start":
				name, err = s.Rec.Start()
			case "stop":
				name, err = s.Rec.Stop()
			case "replay":
				name, err = s.Rec.Replay()
			case "toggle":
				if s.Rec.Recording() {
					did, name, err = "stop", "", nil
					name, err = s.Rec.Stop()
				} else {
					did = "start"
					name, err = s.Rec.Start()
				}
			}
			out := s.Rec.Status()
			out["action"] = did
			if name != "" {
				out["filename"] = name
			}
			if err != nil {
				out["status"] = "error"
				out["message"] = err.Error()
				writeJSON(w, 409, out)
				return
			}
			out["status"] = "ok"
			writeJSON(w, 200, out)
		}
	}
	mux.route("/api/record/start", session, recAct("start"))
	mux.route("/api/record/stop", session, recAct("stop"))
	mux.route("/api/record/toggle", session, recAct("toggle"))
	// ⚠️ The receive audio is MONO. The reference has a stereo variant for a
	// two-receiver capture this host does not do, so it is the SAME call rather
	// than a silent pretence at a second channel.
	mux.route("/api/record/toggle/stereo", session, recAct("toggle"))
	mux.route("/api/record/replay", session, recAct("replay"))

	mux.route("/api/remote-tx/on", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ TWO DIFFERENT FAULTS, TWO DIFFERENT ANSWERS. Folding "no radio
		// attached" into 401 "login required" sends the operator to check their
		// password when the host simply has no rig - a confident wrong answer,
		// which this project has already paid for once on a transmit route.
		if ok, why := s.mayTransmit(r); !ok {
			writeJSON(w, 403, map[string]any{"status": "error", "message": why})
			return
		}
		// ⚠️ THE RADIO DECIDES, PER CALL. This used to be a nil check on a
		// separately-adapted interface, so a host with a simulator did not have
		// the capability at all; now the rig refuses with ErrNotSupported and
		// the reply keeps the same shape the panel already understands.
		if err := s.Rig.SetRemoteTX(true); err != nil {
			if errors.Is(err, rig.ErrNotSupported) {
				writeJSON(w, 503, map[string]any{"status": "error", "supported": false,
					"message": "this host has no radio that can be routed for remote transmit"})
				return
			}
			writeJSON(w, 500, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		rear, usb, err := s.Rig.RemoteTXState()
		// ⚠️ verified is what the RADIO said, and unverified is not the same as
		// failed. The C++ host learned that reporting a plausible value here
		// sends the hunt for a dead transmitter to the wrong end of the chain.
		writeJSON(w, 200, map[string]any{"status": "ok", "remote_tx": rear && usb,
			"verified": err == nil, "mod_source_rear": rear, "rear_select_usb": usb,
			"message": "SSB MOD SOURCE=REAR, REAR SELECT=USB"})
	})

	// ── Control. Every one of these CHANGES THE RADIO. ──────────────────────
	set := func(path string, fn func(string) error) {
		mux.route(path, session, func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			arg := strings.TrimPrefix(r.URL.Path, path)
			// ⚠️ The keying check happens HERE, where the request is, rather
			// than inside the command builder - which has no request and would
			// have to be handed a permission it could silently ignore.
			if path == "/api/ptt/" && arg == "on" {
				if ok, why := s.mayTransmit(r); !ok {
					writeJSON(w, 403, map[string]string{"status": "error", "message": why})
					return
				}
			}
			started := time.Now()
			if err := fn(arg); err != nil {
				// ⚠️ The radio's objection, passed through verbatim. A generic
				// "failed" sends the operator hunting in the wrong place.
				writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
				return
			}
			// ⚠️ How long the RADIO took, not the network. PTT is the one where
			// the operator notices, and it was waiting out a poll cycle.
			writeJSON(w, 200, map[string]any{"status": "ok",
				"ms": time.Since(started).Milliseconds(), "rig": s.Rig.Snapshot()})
		})
	}
	// ⚠️ /api/mode/ is owned by the CAT table in rigroutes.go - it validates the
	// mode name against the radio's codes instead of passing any string through.
	// Registering it in both places is not a merge conflict, it is a panic at
	// startup: net/http refuses two handlers for one pattern.
	set("/api/freq/", func(a string) error {
		hz, err := strconv.ParseInt(a, 10, 64)
		if err != nil {
			return err
		}
		return s.Rig.SetFreq(hz)
	})
	set("/api/ptt/", func(a string) error {
		switch a {
		case "on":
			return s.Rig.SetPTT(true)
		case "off":
			return s.Rig.SetPTT(false)
		}
		return errBadPTT
	})

	// ⚠️ MUTE IS HOST STATE PLUS A CAT WRITE, and it belongs to the rig rather
	// than the client: muting in the panel would leave the operator's own
	// speaker at the radio still making noise, and the C++ host does it this way
	// for that reason.
	for _, m := range []struct {
		path string
		on   bool
	}{{"/api/mute/on", true}, {"/api/mute/off", false}} {
		m := m
		mux.route(m.path, session, func(w http.ResponseWriter, r *http.Request) {
			// ⚠️ A radio that cannot mute answers rig.ErrNotSupported, and the
			// reply says "available: false" exactly as it used to - but the
			// decision is now the RADIO's, not a type assertion's, and it is
			// made per call rather than by whether a method happens to exist.
			if err := s.Rig.SetMuted(m.on); err != nil {
				if errors.Is(err, rig.ErrNotSupported) {
					writeJSON(w, 200, map[string]any{"status": "ok", "available": false,
						"message": "this host's radio cannot be muted"})
					return
				}
				writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"status": "ok", "muted": m.on,
				"rig": s.Rig.Snapshot()})
		})
	}
	mux.route("/api/mute/toggle", session, func(w http.ResponseWriter, r *http.Request) {
		want := !s.Rig.Snapshot().Muted
		if err := s.Rig.SetMuted(want); err != nil {
			if errors.Is(err, rig.ErrNotSupported) {
				writeJSON(w, 200, map[string]any{"status": "ok", "available": false,
					"message": "this host's radio cannot be muted"})
				return
			}
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "muted": want,
			"rig": s.Rig.Snapshot()})
	})

	// ── The antenna tuner ───────────────────────────────────────────────────
	//
	// ⚠️ TWO ROUTES, TWO BOXES. /api/tune is the rig's own ATU; this is the
	// TG-XL. Each names itself in its reply so a confirmation can never say just
	// "tuning" and leave the operator guessing which one is keying up.
	mux.route("/api/tune/tgxl/status", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if s.Tuner == nil || !s.Tuner.Configured() {
			writeJSON(w, 200, map[string]any{"status": "ok", "tuner": "tgxl",
				"available": false, "message": "no tuner configured on this host"})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "tuner": "tgxl",
			"available": true, "tuning": s.Tuner.Active(),
			"device": s.Tuner.Describe(), "message": s.Tuner.Message()})
	})
	mux.route("/api/tune/tgxl", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if s.Tuner == nil || !s.Tuner.Configured() {
			writeJSON(w, 503, map[string]any{"status": "error", "tuner": "tgxl",
				"available": false,
				"message":   "no tuner configured on this host"})
			return
		}
		// ⚠️ THE TUNER KEYS THE TRANSMITTER, SO LOCKDOWN COVERS IT. This check
		// was written once and silently landed on the wrong route, and the test
		// caught the tuner happily answering "keying 15 W CW and tuning" while
		// the station was locked down. A lockdown that stops PTT and leaves a
		// button that puts a carrier on the air has not locked anything down.
		if ok, why := s.mayTransmit(r); !ok {
			writeJSON(w, 403, map[string]any{"status": "error",
				"tuner": "tgxl", "tuning": false, "message": why})
			return
		}
		// ⚠️ Run it in the background and answer immediately. A tune takes 3-15
		// seconds with a carrier on the air; a client waiting on the HTTP reply
		// cannot show progress, and a client that gives up on the request does
		// NOT stop the sequence - the unkey has to stay with the host.
		go func() {
			if err := s.Tuner.Tune(); err != nil {
				log.Printf("tgxl: %v", err)
			}
		}()
		writeJSON(w, 200, map[string]any{"status": "ok", "tuner": "tgxl",
			"available": true, "tuning": true,
			"message": "keying 15 W CW and tuning"})
	})

	// ⚠️ THE SAME TUNER UNDER ITS OTHER NAME. The C++ host answers both
	// /api/tune/tgxl and /api/tgxl/tune, and a client built against either one
	// must work. An alias is cheaper than an operator finding out which spelling
	// their client uses at the moment they want to tune.
	mux.route("/api/tgxl/tune", session, func(w http.ResponseWriter, r *http.Request) {
		r2 := r.Clone(r.Context())
		r2.URL.Path = "/api/tune/tgxl"
		real.ServeHTTP(w, r2)
	})

	// What the transmit audio path is and what it could be.
	mux.route("/api/tx-audio/status", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, map[string]any{"status": "ok", "tx": txStats(s.Tx)})
	})
	mux.route("/api/tx-audio/devices", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ THE MICROPHONE IS ON THE CLIENT, NOT HERE. On the C++ host the
		// transmit audio device is the machine's own sound card; on this one the
		// operator's microphone lives in the panel, and the host's transmit
		// device is the fixed link into the radio. Listing the host's inputs
		// would offer the operator a choice that changes nothing they can hear.
		writeJSON(w, 200, map[string]any{"status": "ok",
			"devices": []any{},
			"message": "the microphone is chosen in the client; this host's transmit device is the link to the radio",
			"host_device": func() string {
				if s.Tx == nil {
					return ""
				}
				return s.Tx.Describe()
			}()})
	})

	// ⚠️ REGISTERED WHETHER OR NOT THERE IS A RADIO. These used to appear only
	// when a rig was attached, so the route list - and therefore the parity
	// checklist - changed shape depending on what was plugged in. A client
	// cannot ask "does this host support remote transmit" if the answer is a
	// 404 that also means "wrong URL".
	mux.route("/api/remote-tx/status", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		rear, usb, err := s.Rig.RemoteTXState()
		if errors.Is(err, rig.ErrNotSupported) {
			writeJSON(w, 200, map[string]any{"status": "ok", "supported": false})
			return
		}
		if err != nil {
			// ⚠️ Unverified is NOT the same as false. Saying "MIC" when the
			// read failed would be a confident wrong answer about a
			// transmitter.
			writeJSON(w, 200, map[string]any{"status": "ok", "verified": false,
				"message": "the radio did not answer: " + err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "verified": true,
			"mod_source_rear": rear, "rear_select_usb": usb,
			"hand_mic_live": !rear})
	})

	mux.route("/api/remote-tx/off", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ UNKEY FIRST, THEN HAND THE MICROPHONE BACK. Putting MOD SOURCE back
		// to MIC while the transmitter is keyed leaves a keyed radio modulated
		// by whatever is in front of it.
		_ = s.Rig.SetPTT(false)
		// ⚠️ "Cannot route" and "refused to route back" are different answers.
		// Folding them together made this reply 502 on a host with a simulator -
		// an error about a transmitter that was never routed in the first place.
		if err := s.Rig.SetRemoteTX(false); err != nil {
			if errors.Is(err, rig.ErrNotSupported) {
				writeJSON(w, 503, map[string]any{"status": "error", "supported": false,
					"message": "this host has no radio that can be routed for remote transmit"})
				return
			}
			writeJSON(w, 502, map[string]any{"status": "error",
				"message": "the radio did not take the routing back: " + err.Error()})
			return
		}
		rear, usb, rerr := s.Rig.RemoteTXState()
		writeJSON(w, 200, map[string]any{"status": "ok", "remote_tx": rear && usb,
			"verified": rerr == nil, "mod_source_rear": rear, "rear_select_usb": usb,
			"hand_mic_live": !rear})
	})

	// ── Everything else the radio can do, from the ported CAT table ────────
	if s.Flags == nil {
		s.Flags = newHostFlags()
	}
	if s.Lock == nil {
		s.Lock = &Lockdown{}
	}
	s.registerAdmin(mux)
	s.registerHostFlags(mux)
	s.registerCAT(mux)

	// What this host actually serves, from the registrations themselves.
	mux.route("/api/routes", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		out := append([]string(nil), registered...)
		sort.Strings(out)
		writeJSON(w, 200, map[string]any{"status": "ok", "count": len(out), "routes": out})
	})

	// ── The receiver ────────────────────────────────────────────────────────
	if s.Audio != nil {
		// ⚠️ session, AND THE POLICY RUNS BEFORE THE UPGRADE. Anonymous receive
		// audio means anyone who can reach this host can listen to the
		// operator's receiver - the C++ host shipped exactly that once and it
		// was a security fix, not a feature. route() answers 401 without ever
		// reaching the handler, so the socket is never accepted.
		mux.route("/ws", session, func(w http.ResponseWriter, r *http.Request) {
			conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
				// Same origin as the panel this host serves; a browser sends the
				// page's origin and nothing else is expected.
				OriginPatterns: []string{"*"},
			})
			if err != nil {
				return
			}
			defer conn.CloseNow()
			s.Audio.Serve(r.Context(), conn)
		})

		// ── Transmit audio ──────────────────────────────────────────────────
		// ⚠️ OPENING THIS SOCKET IS ARMING THE TRANSMITTER. It claims the audio
		// path and points the RADIO at it (MOD SOURCE=REAR, REAR SELECT=USB),
		// because on MIC the rig ignores the codec completely: it keys, ALC sits
		// at idle, power reads 0, and nothing anywhere reports a fault.
		//
		// ⚠️ AND CLOSING IT HANDS THE STATION BACK. Unkey FIRST, then restore
		// MIC - in that order, because a client that died while keyed leaves a
		// carrier up, and putting MOD SOURCE back to MIC before unkeying means
		// that open carrier is then modulated by whatever the shack can hear,
		// with nobody at the station. The C++ host has that scar; this does not
		// need to earn it again.
		mux.route("/ws/tx", session, func(w http.ResponseWriter, r *http.Request) {
			if ok, why := s.mayTransmit(r); !ok {
				writeJSON(w, 403, map[string]any{"status": "error", "message": why})
				return
			}
			if s.Tx == nil && s.TxRec == nil {
				writeJSON(w, 503, map[string]string{"status": "error",
					"message": "this host has no transmit audio device"})
				return
			}
			conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{"*"}})
			if err != nil {
				return
			}
			defer conn.CloseNow()

			// ⚠️ THE HOST NAMES THE FORMAT IT WANTS, FIRST. Capture and playback
			// on this codec negotiated DIFFERENT rates (22050 in, 44100 out), so
			// a client that reused the receive rate for transmit would send a
			// voice at half speed - transmitting fine, metering fine, and
			// unintelligible to everyone except the operator.
			txRate, txCh := 0, 0
			if s.Tx != nil {
				txRate, txCh = s.Tx.Rate(), s.Tx.Channels()
			} else {
				txRate, txCh = s.TxRec.Rate(), s.TxRec.Channels()
			}
			hello := fmt.Sprintf(`{"rate":%d,"channels":%d,"format":"s16le"}`,
				txRate, txCh)
			if err := conn.Write(r.Context(), websocket.MessageText, []byte(hello)); err != nil {
				return
			}

			{
				// ⚠️ A rig that cannot route refuses here and the socket says so,
				// rather than the transmit path silently not existing.
				if err := s.Rig.SetRemoteTX(true); err != nil && !errors.Is(err, rig.ErrNotSupported) {
					conn.Write(r.Context(), websocket.MessageText,
						[]byte(`{"status":"error","message":"could not route the radio to USB"}`))
					return
				}
				rear, usb, rerr := s.Rig.RemoteTXState()
				// ⚠️ What the RADIO answered, not what was sent. "Unverified" is
				// not the same as "failed", and both are different from "ok".
				msg := fmt.Sprintf(`{"remote_tx":%t,"verified":%t,"mod_source_rear":%t,"rear_select_usb":%t}`,
					rear && usb, rerr == nil, rear, usb)
				conn.Write(r.Context(), websocket.MessageText, []byte(msg))
			}
			defer func() {
				{
					_ = s.Rig.SetPTT(false) // unkey FIRST
					time.Sleep(50 * time.Millisecond)
					_ = s.Rig.SetRemoteTX(false) // then hand the mic back
				}
			}()

			for {
				typ, data, err := conn.Read(r.Context())
				if err != nil {
					return
				}
				if typ == websocket.MessageBinary {
					if s.Tx != nil {
						s.Tx.Write(data)
					}
					if s.TxRec != nil {
						s.TxRec.Write(data)
					}
				}
			}
		})

		// ⚠️ WHAT THE RADIO IS ROUTED TO, ASKED OF THE RADIO. Without this an
		// operator cannot tell why a keyed transmitter is putting out nothing -
		// and "the commands were sent" is not an answer, because MOD SOURCE
		// silently reverting to MIC is the single most expensive failure this
		// project has had. It is also how you find out your hand mic is dead
		// because a remote client left the rig on REAR.

		// What the audio path is actually doing, as numbers a person can read.
		mux.route("/api/audio", session, func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			peak := s.Audio.Peak()
			writeJSON(w, 200, map[string]any{
				"status": "ok", "device": s.Audio.Describe(),
				"rate": s.Audio.Rate, "channels": s.Audio.Channels,
				"listeners": s.Audio.Clients(),
				// ⚠️ The LEVEL, not "frames were read". Silence and a dead
				// receiver are indistinguishable without it.
				"peak": peak, "peak_pct": peak * 100 / 32767,
				"tx": txStats(s.Tx),
			})
		})
	}

	if s.AltPanelDir != "" {
		real.Handle("/alt/", http.StripPrefix("/alt/", http.FileServer(http.Dir(s.AltPanelDir))))
	}
	if s.PanelDir != "" {
		// Registered last so every /api/ route above wins; the panel takes the
		// rest, including deep links a browser reload asks for.
		real.Handle("/", http.FileServer(http.Dir(s.PanelDir)))
	}
	return logging(real)
}

var errBadPTT = &ptterr{}

type ptterr struct{}

func (*ptterr) Error() string { return "ptt takes on or off" }

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// ⚠️ Never log the query string: the audio socket carries the session
		// token there, and a token in a log file is a credential in a log file.
		log.Printf("%s %s (%v)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

// ⚠️ THE TRANSMIT SIDE REPORTS THE LEVEL THAT REACHED THE RADIO, and the frames
// it could not play. A microphone that is muted, a browser that captured
// nothing, and a working operator all produce frames at exactly the right rate -
// only the level tells them apart.
func txStats(t *audio.TxSink) map[string]any {
	if t == nil {
		return map[string]any{"device": "none"}
	}
	written, dropped := t.Stats()
	peak := t.Peak()
	return map[string]any{
		"device": t.Describe(), "peak": peak, "peak_pct": peak * 100 / 32767,
		"frames_written": written, "dropped": dropped,
	}
}
