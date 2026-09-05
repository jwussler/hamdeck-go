package api

import (
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jwussler/hamdeck-go/internal/auth"
	"github.com/jwussler/hamdeck-go/internal/rig"
)

// ⚠️ THESE TWO PROTECT A TRANSMITTER, WHICH IS WHY THEY ARE WORTH TESTING AT ALL.
//
// Everything else in this package answers a question wrongly at worst. These
// decide whether a radio keys, and on what frequency in what mode - and both are
// pure enough to check exhaustively in microseconds, which is the best ratio of
// safety to effort anywhere in the host.

func txTestServer(t *testing.T) (*Server, *auth.Service) {
	t.Helper()
	store := auth.NewStore(filepath.Join(t.TempDir(), "users.json"))
	a := auth.New(store, 480)
	if err := a.Load(); err != nil {
		t.Fatalf("load: %v", err)
	}
	if err := a.SetPassword("op", "pw", true); err != nil {
		t.Fatalf("seed: %v", err)
	}
	return &Server{Rig: rig.NewSim(), Auth: a, Version: "test", Lock: &Lockdown{}}, a
}

// ⚠️ TWO SEPARATE REFUSALS, NAMED SEPARATELY. "Locked down" and "your account
// cannot transmit" are different problems with different fixes, and folding them
// into one message sends somebody to the wrong person for help.
func TestMayTransmitNamesTheRightRefusal(t *testing.T) {
	s, a := txTestServer(t)
	tok := a.Login("op", "pw")
	if tok == "" {
		t.Fatal("the operator could not log in")
	}
	r := httptest.NewRequest("GET", "/api/ptt/on?token="+tok, nil)

	// The first account is the administrator and may transmit.
	if ok, why := s.mayTransmit(r); !ok {
		t.Fatalf("an account that may transmit was refused: %s", why)
	}

	// Lockdown refuses, and says lockdown.
	s.Lock.Set(true, "locked by tester")
	ok, why := s.mayTransmit(r)
	if ok {
		t.Fatal("LOCKDOWN DID NOT STOP A TRANSMIT - the lock is a label, not a lock")
	}
	if !strings.Contains(why, "locked down") {
		t.Errorf("a lockdown refusal must say so; got %q", why)
	}
	s.Lock.Set(false, "")

	// An account without transmit permission is refused differently.
	if err := a.SetPassword("listener", "pw2", true); err != nil {
		t.Fatalf("seed listener: %v", err)
	}
	p := a.PermsOf("listener")
	p.CanTransmit = false
	if err := a.SetPerms("listener", p); err != nil {
		t.Fatalf("set perms: %v", err)
	}
	ltok := a.Login("listener", "pw2")
	if ltok == "" {
		t.Fatal("the listener could not log in")
	}
	lr := httptest.NewRequest("GET", "/api/ptt/on?token="+ltok, nil)
	ok, why = s.mayTransmit(lr)
	if ok {
		t.Fatal("AN ACCOUNT THAT CANNOT TRANSMIT WAS ALLOWED TO KEY THE RADIO")
	}
	if !strings.Contains(why, "listen but not transmit") {
		t.Errorf("a permission refusal must say which; got %q", why)
	}

	// ⚠️ And a token nobody issued is not a session. This is the one that keeps
	// an anonymous caller off the transmitter.
	nr := httptest.NewRequest("GET", "/api/ptt/on?token=not-a-real-token", nil)
	if ok, _ := s.mayTransmit(nr); ok {
		t.Fatal("A TOKEN NOBODY ISSUED WAS ALLOWED TO TRANSMIT")
	}
}

// ⚠️ CHANGING BAND WITHOUT CHANGING MODE LANDS YOU ON 40 m IN USB, which is
// legal, wrong, and sounds like a broken radio to everyone listening. The band
// plan rides along with every frequency change, so it is worth pinning exactly.
func TestBandPlanMode(t *testing.T) {
	for _, c := range []struct {
		hz   int64
		want string
		why  string
	}{
		{1_840_000, "LSB", "160 m"},
		{3_860_000, "LSB", "80 m"},
		{5_330_500, "USB", "60 m is USB by band plan whatever the frequency suggests"},
		{5_403_500, "USB", "still 60 m"},
		{7_200_000, "LSB", "40 m"},
		{9_999_999, "LSB", "just below the 10 MHz crossover"},
		{10_120_000, "CW", "30 m is CW and digital only"},
		{10_100_000, "CW", "the bottom edge of 30 m"},
		{10_150_000, "CW", "the top edge of 30 m"},
		{14_200_000, "USB", "20 m"},
		{21_300_000, "USB", "15 m"},
		{50_125_000, "USB", "6 m"},
	} {
		if got := modeForFreq(c.hz); got != c.want {
			t.Errorf("%d Hz (%s): got %s, want %s", c.hz, c.why, got, c.want)
		}
	}
}

// ⚠️ THE EDGES ARE THE POINT. 10 MHz exactly is below the 30 m band and must not
// come back CW, and 10,150,001 is out the top of it. An off-by-one here puts an
// operator in the wrong mode on a band where one of the two is not allowed.
func TestBandPlanEdges(t *testing.T) {
	if got := modeForFreq(10_000_000); got != "USB" {
		t.Errorf("10.000000 MHz is not in 30 m and is not below 10 MHz: got %s", got)
	}
	if got := modeForFreq(10_150_001); got != "USB" {
		t.Errorf("just above 30 m must not stay CW: got %s", got)
	}
	if got := modeForFreq(5_299_999); got != "LSB" {
		t.Errorf("just below 60 m is not 60 m: got %s", got)
	}
	if got := modeForFreq(5_500_001); got != "LSB" {
		t.Errorf("just above 60 m is not 60 m: got %s", got)
	}
}
