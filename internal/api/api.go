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
	"fmt"
	"log"
	"net/http"
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
	Tx  *audio.TxSink
	Rig2 interface {
		SetRemoteTX(bool) error
		RemoteTXState() (bool, bool, error)
		SetPTT(bool) error
	}
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

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// Health takes no session on purpose: it is how you ask "is the host up"
	// without holding a credential, and it says nothing about the band.
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, map[string]any{
			"status": "ok", "service": "HamDeck API (Go)", "version": s.Version,
			"rig": s.Rig.Describe(), "rig_connected": s.Rig.Snapshot().Connected,
			"auth_configured": s.Auth.Configured(),
		})
	})

	mux.HandleFunc("/api/auth/login", func(w http.ResponseWriter, r *http.Request) {
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

	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if !s.authed(r) {
			writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
			return
		}
		writeJSON(w, 200, s.Rig.Snapshot())
	})

	// ── Control. Every one of these CHANGES THE RADIO. ──────────────────────
	set := func(path string, fn func(string) error) {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			if !s.authed(r) {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
			arg := strings.TrimPrefix(r.URL.Path, path)
			if err := fn(arg); err != nil {
				// ⚠️ The radio's objection, passed through verbatim. A generic
				// "failed" sends the operator hunting in the wrong place.
				writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"status": "ok", "rig": s.Rig.Snapshot()})
		})
	}
	set("/api/mode/", func(a string) error { return s.Rig.SetMode(strings.ToUpper(a)) })
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

	// ── The receiver ────────────────────────────────────────────────────────
	if s.Audio != nil {
		mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
			if !s.authed(r) {
				// ⚠️ 401 BEFORE THE UPGRADE. Anonymous receive audio means
				// anyone who can reach this host can listen to the operator's
				// receiver - the C++ host shipped exactly that once and it was
				// a security fix, not a feature.
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
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
		mux.HandleFunc("/ws/tx", func(w http.ResponseWriter, r *http.Request) {
			if !s.authed(r) {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
			if s.Tx == nil {
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
			hello := fmt.Sprintf(`{"rate":%d,"channels":%d,"format":"s16le"}`,
				s.Tx.Rate(), s.Tx.Channels())
			if err := conn.Write(r.Context(), websocket.MessageText, []byte(hello)); err != nil {
				return
			}

			if s.Rig2 != nil {
				if err := s.Rig2.SetRemoteTX(true); err != nil {
					conn.Write(r.Context(), websocket.MessageText,
						[]byte(`{"status":"error","message":"could not route the radio to USB"}`))
					return
				}
				rear, usb, rerr := s.Rig2.RemoteTXState()
				// ⚠️ What the RADIO answered, not what was sent. "Unverified" is
				// not the same as "failed", and both are different from "ok".
				msg := fmt.Sprintf(`{"remote_tx":%t,"verified":%t,"mod_source_rear":%t,"rear_select_usb":%t}`,
					rear && usb, rerr == nil, rear, usb)
				conn.Write(r.Context(), websocket.MessageText, []byte(msg))
			}
			defer func() {
				if s.Rig2 != nil {
					_ = s.Rig2.SetPTT(false) // unkey FIRST
					time.Sleep(50 * time.Millisecond)
					_ = s.Rig2.SetRemoteTX(false) // then hand the mic back
				}
			}()

			for {
				typ, data, err := conn.Read(r.Context())
				if err != nil {
					return
				}
				if typ == websocket.MessageBinary {
					s.Tx.Write(data)
				}
			}
		})

		// What the audio path is actually doing, as numbers a person can read.
		mux.HandleFunc("/api/audio", func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			if !s.authed(r) {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
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
		mux.Handle("/alt/", http.StripPrefix("/alt/", http.FileServer(http.Dir(s.AltPanelDir))))
	}
	if s.PanelDir != "" {
		// Registered last so every /api/ route above wins; the panel takes the
		// rest, including deep links a browser reload asks for.
		mux.Handle("/", http.FileServer(http.Dir(s.PanelDir)))
	}
	return logging(mux)
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
