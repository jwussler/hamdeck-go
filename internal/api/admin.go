package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"

	"github.com/jwussler/hamdeck-go/internal/auth"
)

// Lockdown stops the station transmitting, from anywhere.
//
// ⚠️ IT LIVES IN THE HOST, NEXT TO THE RADIO. A lockdown a client enforces is
// not a lockdown: the client that is misbehaving is the one being asked to stop.
// Every transmit path checks this, so turning it on genuinely takes the
// transmitter away rather than hiding the button.
type Lockdown struct {
	mu     sync.RWMutex
	on     bool
	reason string
}

func (l *Lockdown) On() bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.on
}

func (l *Lockdown) Reason() string {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.reason
}

func (l *Lockdown) Set(on bool, reason string) {
	l.mu.Lock()
	l.on, l.reason = on, reason
	l.mu.Unlock()
}

func (s *Server) registerAdmin(mux routeMux) {
	// ⚠️ EVERY ROUTE HERE NEEDS A SESSION, and the check is at the top of each
	// one rather than in a wrapper somebody can forget to apply. The C++ host
	// gates /api/admin/ by prefix; this does the same thing explicitly, because
	// a prefix gate that stops matching after a rename fails OPEN.
	admin := func(fn func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			cors(w, r)
			tok := token(r)
			who := s.Auth.Who(tok)
			if who == "" {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
			// ⚠️ ADMIN ROUTES NEED THE ADMIN FLAG, not just a session. Every
			// logged-in user could add accounts and lock down the station
			// otherwise, which makes the read-only "listener" account a
			// full administrator.
			if strings.HasPrefix(r.URL.Path, "/api/admin/") && !s.Auth.IsAdmin(tok) {
				writeJSON(w, 403, map[string]string{"status": "error",
					"message": "that needs an administrator account"})
				return
			}
			fn(w, r, who)
		}
	}

	mux.HandleFunc("/api/auth/status", func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		who := s.Auth.Who(token(r))
		writeJSON(w, 200, map[string]any{"status": "ok",
			"authenticated": who != "", "user": who,
			"configured": s.Auth.Configured()})
	})

	mux.HandleFunc("/api/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		// ⚠️ Reports whether a session was really ended. Answering "ok" for a
		// token that was already gone tells an operator they logged out of
		// something when nothing happened.
		ended := s.Auth.Logout(token(r))
		writeJSON(w, 200, map[string]any{"status": "ok", "ended": ended})
	})

	mux.HandleFunc("/api/admin/sessions", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		writeJSON(w, 200, map[string]any{"status": "ok", "sessions": s.Auth.Sessions()})
	}))

	mux.HandleFunc("/api/admin/users", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		users := []map[string]any{}
		for _, u := range s.Auth.Users() {
			// ⚠️ Users() already strips the hash. A list of accounts rendered in
			// a browser must not carry the thing that protects them.
			users = append(users, map[string]any{"username": u.Username,
				"perms": s.Auth.PermsOf(u.Username)})
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "users": users})
	}))

	mux.HandleFunc("/api/admin/user/add", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		name, pw, err := userBody(r)
		if err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		if s.Auth.Exists(name) {
			// ⚠️ "Add" must not silently reset an existing account's password.
			// There is a route for that, and conflating them means a typo in a
			// username changes somebody else's credential.
			writeJSON(w, 400, map[string]string{"status": "error",
				"message": "there is already an account called " + name})
			return
		}
		if err := s.Auth.SetPassword(name, pw, true); err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		// ⚠️ It survives a restart now - accounts live in the store, not in this
		// process - and it starts with NO permissions, which has to be said or
		// the operator finds out when the person cannot key up.
		writeJSON(w, 200, map[string]any{"status": "ok", "user": name,
			"perms":   s.Auth.PermsOf(name),
			"message": "added. It may listen but not transmit until granted /api/admin/user/tx/" + name + "/on"})
	}))

	mux.HandleFunc("/api/admin/user/password", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		name, pw, err := userBody(r)
		if err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		// ⚠️ create=false: this route resets a password, it does not invent an
		// account. A typo here would otherwise become a login.
		if err := s.Auth.SetPassword(name, pw, false); err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "user": name})
	}))

	mux.HandleFunc("/api/admin/user/remove/", admin(func(w http.ResponseWriter, r *http.Request, who string) {
		name := strings.TrimPrefix(r.URL.Path, "/api/admin/user/remove/")
		if name == who {
			// ⚠️ Refuse to remove yourself. It is always a mistake, and the
			// person who made it is now the person who cannot log in to fix it.
			writeJSON(w, 400, map[string]string{"status": "error",
				"message": "that is the account you are logged in as"})
			return
		}
		if err := s.Auth.Remove(name); err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "removed": name,
			"message": "account removed and its sessions ended"})
	}))

	mux.HandleFunc("/api/admin/kick/", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		id := strings.TrimPrefix(r.URL.Path, "/api/admin/kick/")
		if len(id) < 4 {
			// A short prefix would match half the sessions on the host.
			writeJSON(w, 400, map[string]string{"status": "error",
				"message": "give at least the first 4 characters of the session id"})
			return
		}
		n := s.Auth.Kick(id)
		writeJSON(w, 200, map[string]any{"status": "ok", "ended": n})
	}))

	// Per-account permissions, the three flags the station config carries.
	for _, f := range []struct {
		path string
		set  func(*auth.Perms, bool)
	}{
		{"/api/admin/user/tx/", func(p *auth.Perms, v bool) { p.CanTransmit = v }},
		{"/api/admin/user/admin/", func(p *auth.Perms, v bool) { p.IsAdmin = v }},
		{"/api/admin/user/station/", func(p *auth.Perms, v bool) { p.IsStation = v }},
	} {
		f := f
		mux.HandleFunc(f.path, admin(func(w http.ResponseWriter, r *http.Request, who string) {
			// <name>/<on|off>
			rest := strings.TrimPrefix(r.URL.Path, f.path)
			name, val, ok := strings.Cut(rest, "/")
			if !ok || (val != "on" && val != "off") {
				writeJSON(w, 400, map[string]string{"status": "error",
					"message": "expected <username>/<on|off>"})
				return
			}
			// ⚠️ You cannot remove your own admin rights. It is always a
			// mistake and the person who made it is the one who can no longer
			// undo it.
			if name == who && f.path == "/api/admin/user/admin/" && val == "off" {
				writeJSON(w, 400, map[string]string{"status": "error",
					"message": "that would remove your own administrator access"})
				return
			}
			p := s.Auth.PermsOf(name)
			f.set(&p, val == "on")
			if err := s.Auth.SetPerms(name, p); err != nil {
				writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"status": "ok", "user": name, "perms": p})
		}))
	}

	// ── Lockdown and the remote unkey ───────────────────────────────────────
	mux.HandleFunc("/api/admin/lockdown/status", s.guard(func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, map[string]any{"status": "ok",
			"lockdown": s.Lock.On(), "reason": s.Lock.Reason()})
	}))
	mux.HandleFunc("/api/admin/lockdown/on", admin(func(w http.ResponseWriter, r *http.Request, who string) {
		s.Lock.Set(true, "locked by "+who)
		// ⚠️ Turning lockdown on UNKEYS. Locking a transmitter that is currently
		// keyed and leaving it keyed is not a lockdown, it is a label.
		if s.Rig2 != nil {
			_ = s.Rig2.SetPTT(false)
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "lockdown": true,
			"reason": s.Lock.Reason(), "unkeyed": s.Rig2 != nil})
	}))
	mux.HandleFunc("/api/admin/lockdown/off", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		s.Lock.Set(false, "")
		writeJSON(w, 200, map[string]any{"status": "ok", "lockdown": false})
	}))

	// ⚠️ THE PANIC BUTTON. It does not ask the client that is transmitting to
	// stop - it drops PTT at the radio. A stuck client, a crashed one and a
	// forgotten one all look the same from here, and all three are fixed by this.
	mux.HandleFunc("/api/admin/unkey", admin(func(w http.ResponseWriter, r *http.Request, _ string) {
		if s.Rig2 == nil {
			writeJSON(w, 503, map[string]any{"status": "error",
				"message": "this host has no radio to unkey"})
			return
		}
		err := s.Rig2.SetPTT(false)
		if err != nil {
			writeJSON(w, 502, map[string]any{"status": "error",
				"message": "the radio did not accept the unkey: " + err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "unkeyed": true})
	}))

	// What the host is, for a client deciding which controls to show.
	mux.HandleFunc("/api/remote/status", s.guard(func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		writeJSON(w, 200, map[string]any{"status": "ok",
			"rig":       s.Rig.Describe(),
			"audio":     s.Audio != nil,
			"transmit":  s.Tx != nil,
			"tuner":     s.Tuner != nil && s.Tuner.Configured(),
			"recording": s.Rec != nil,
			"lockdown":  s.Lock.On(),
		})
	}))
}

func token(r *http.Request) string {
	if t := r.URL.Query().Get("token"); t != "" {
		return t
	}
	h := r.Header.Get("Authorization")
	return strings.TrimPrefix(h, "Bearer ")
}

func userBody(r *http.Request) (string, string, error) {
	var b struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		return "", "", errBadUserBody
	}
	b.Username = strings.TrimSpace(b.Username)
	if b.Username == "" || b.Password == "" {
		// ⚠️ An empty password is refused, never hashed. A blank credential that
		// hashes fine is an account anybody can log into.
		return "", "", errBadUserBody
	}
	return b.Username, b.Password, nil
}

var errBadUserBody = &badBody{}

type badBody struct{}

func (*badBody) Error() string {
	return "send a JSON body with a username and a non-empty password"
}
