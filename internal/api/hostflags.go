package api

import (
	"net/http"
	"sync"
)

// Flags the HOST remembers, which the radio knows nothing about.
//
// ⚠️ THESE SEND NO CAT, AND THAT IS FAITHFUL, NOT LAZY. In the C++ host
// /api/diversity/* and /api/vfo-lock/* flip a boolean in host state and report
// it back - they never touch the radio. Porting them as radio commands would
// invent verbs the reference never sends, and a control that claims to change
// the rig while changing nothing is the worst kind of wrong: it looks like it
// worked.
//
// They exist because the panel needs somewhere to keep a setting that outlives
// one client - two operators on two machines see the same state.
type hostFlags struct {
	mu sync.RWMutex
	v  map[string]bool
}

func newHostFlags() *hostFlags { return &hostFlags{v: map[string]bool{}} }

func (h *hostFlags) get(k string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.v[k]
}

func (h *hostFlags) set(k string, on bool) {
	h.mu.Lock()
	h.v[k] = on
	h.mu.Unlock()
}

func (h *hostFlags) toggle(k string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.v[k] = !h.v[k]
	return h.v[k]
}

func (s *Server) registerHostFlags(mux routeMux) {
	for _, f := range []struct{ route, key string }{
		{"/api/diversity", "diversity"},
		{"/api/vfo-lock", "vfo_locked"},
	} {
		f := f
		reply := func(w http.ResponseWriter, r *http.Request, v bool) {
			cors(w, r)
			writeJSON(w, 200, map[string]any{"status": "ok", f.key: v,
				// ⚠️ Say where this lives. An operator debugging why the radio's
				// front panel disagrees needs to know nothing was ever sent to it.
				"scope": "host flag - not sent to the radio"})
		}
		// ⚠️ A SESSION, EVEN THOUGH NO CAT LEAVES THE HOST. These were open to
		// anyone who could reach the port: /on and /off CHANGE state two
		// operators share, and "it does not touch the radio" is not the same as
		// "it does not matter" - the panel draws these as though they were the
		// station's own settings.
		mux.route(f.route+"/on", session, func(w http.ResponseWriter, r *http.Request) {
			s.Flags.set(f.key, true)
			reply(w, r, true)
		})
		mux.route(f.route+"/off", session, func(w http.ResponseWriter, r *http.Request) {
			s.Flags.set(f.key, false)
			reply(w, r, false)
		})
		mux.route(f.route+"/status", session, func(w http.ResponseWriter, r *http.Request) {
			reply(w, r, s.Flags.get(f.key))
		})
	}
	// ⚠️ /api/vfo-lock/toggle is NOT here: it is a real CAT toggle (LK) in the
	// table, and the C++ host has both a host flag and a rig lock under names
	// one letter apart. Registering this one too would shadow it, and the
	// operator would get a boolean that pretends to be a locked VFO.
	mux.route("/api/diversity/toggle", session, func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		v := s.Flags.toggle("diversity")
		writeJSON(w, 200, map[string]any{"status": "ok", "diversity": v,
			"scope": "host flag - not sent to the radio"})
	})
}
