package api

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jwussler/hamdeck-go/internal/auth"
	"github.com/jwussler/hamdeck-go/internal/rig"
)

// ⚠️ THIS IS tools/check_auth.py, AS A UNIT TEST.
//
// That script is the only thing that has ever caught an unguarded route, and it
// has earned its keep twice in one day: a scripted edit stripped the session
// check out of guard() ITSELF and 121 routes answered anonymously while the host
// built, vetted, started and served perfectly; and the same pass made
// /api/auth/login require a session, which is a bootstrap deadlock.
//
// But it needs a built binary, a spare port, a running host and a network, so it
// only runs in preflight - minutes after the mistake, if somebody remembers. The
// same question can be asked of the real Handler() in-process in milliseconds,
// on every commit and in CI. That is what this does.
//
// ⚠️ IT ASSERTS THE POLICY, NOT A LIST. A test carrying its own copy of the
// route table would pass while the server served something else; this walks
// whatever Handler() actually registered.

// openOnPurpose is the entire set of routes allowed to answer without a session,
// and each one is a decision.
//
// ⚠️ ADDING TO THIS LIST IS THE POINT OF FAILURE. It is small, it is here rather
// than spread across handlers, and a route that appears in it should be arguable
// out loud - which is why each carries the argument.
var openOnPurpose = map[string]string{
	"/api/health":      "how you ask 'is the host up' without holding a credential; it says nothing about the band",
	"/api/auth/login":  "the door itself - requiring a session to log in is a bootstrap deadlock",
	"/api/auth/logout": "acts only on the caller's OWN token; needing a valid session to end one makes a half-expired token unloggable-out",
	"/api/auth/status": "says whether a session exists and carries nothing about the station",
}

func testServer(t *testing.T) (*Server, http.Handler) {
	t.Helper()
	store := auth.NewStore(filepath.Join(t.TempDir(), "users.json"))
	a := auth.New(store, 480)
	if err := a.Load(); err != nil {
		t.Fatalf("load: %v", err)
	}
	if err := a.SetPassword("tester", "a-real-password", true); err != nil {
		t.Fatalf("seed: %v", err)
	}
	s := &Server{Rig: rig.NewSim(), Auth: a, Version: "test"}
	return s, s.Handler()
}

// Every registered route either needs a session or is on the short list above.
func TestEveryRouteNeedsASession(t *testing.T) {
	s, h := testServer(t)

	var anonymous []string
	for _, path := range s.Routes() {
		if _, ok := openOnPurpose[path]; ok {
			continue
		}
		// A prefix route is registered with a trailing slash; give it an
		// argument so it reaches the handler rather than 404ing on shape.
		req := path
		if strings.HasSuffix(path, "/") {
			req += "x"
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, req, nil))
		if w.Code != http.StatusUnauthorized && w.Code != http.StatusForbidden {
			anonymous = append(anonymous, path)
		}
	}
	if len(anonymous) > 0 {
		t.Fatalf("%d route(s) answered with NO SESSION - anyone who can reach this host "+
			"can use them:\n  %s", len(anonymous), strings.Join(anonymous, "\n  "))
	}
}

// ⚠️ AND THE OPEN ONES MUST STILL BE OPEN. A change that locked /api/auth/login
// would pass the test above and lock every operator out of the station.
func TestTheOpenRoutesStayOpen(t *testing.T) {
	_, h := testServer(t)
	for path, why := range openOnPurpose {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		// ⚠️ THE STATUS CODE IS NOT THE SIGNAL - THE REASON IS. /api/auth/login
		// answers 401 to a request with no credentials, which is correct and has
		// nothing to do with sessions; an earlier version of this test read that
		// as "the door is locked" and failed on working code. What must never
		// appear on these routes is the session refusal itself.
		if strings.Contains(w.Body.String(), "login required") {
			t.Errorf("%s now demands a session, but it is open on purpose: %s", path, why)
		}
	}
}

// ⚠️ A SESSION IS NOT ADMINISTRATION. Every logged-in user could otherwise add
// accounts and lock the station down, which turns the read-only listener account
// into a full administrator.
func TestAdminRoutesNeedMoreThanASession(t *testing.T) {
	store := auth.NewStore(filepath.Join(t.TempDir(), "users.json"))
	a := auth.New(store, 480)
	if err := a.Load(); err != nil {
		t.Fatalf("load: %v", err)
	}
	// The first account is the administrator, so make a second that is not.
	if err := a.SetPassword("boss", "pw-one", true); err != nil {
		t.Fatalf("seed admin: %v", err)
	}
	if err := a.SetPassword("listener", "pw-two", true); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	tok := a.Login("listener", "pw-two")
	if tok == "" {
		t.Fatal("the non-admin account could not log in")
	}
	if a.IsAdmin(tok) {
		t.Fatal("the second account is an administrator - this test proves nothing")
	}

	s := &Server{Rig: rig.NewSim(), Auth: a, Version: "test"}
	h := s.Handler()
	for _, path := range s.Routes() {
		if !strings.HasPrefix(path, "/api/admin/") {
			continue
		}
		req := path
		if strings.HasSuffix(path, "/") {
			req += "someone/on"
		}
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, req+"?token="+tok, nil)
		h.ServeHTTP(w, r)
		// lockdown/status is deliberately readable by any session - it tells an
		// operator why they cannot transmit.
		if path == "/api/admin/lockdown/status" {
			continue
		}
		if w.Code != http.StatusForbidden {
			t.Errorf("%s answered %d for a NON-ADMIN session; it must be 403", path, w.Code)
		}
	}
}
