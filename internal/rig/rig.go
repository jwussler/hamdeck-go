// Package rig is the radio, behind an interface.
//
// ⚠️ THE INTERFACE IS THE POINT, AND IT IS THE ONE THING THE C++ HOST GOT WRONG
// FROM THE START. There, the CAT verbs are hardcoded for an FTDX-101 and adding a
// second radio means touching the transport. Here a radio is a Rig, the simulator
// and a real serial port are both just Rigs, and a second model is a table rather
// than a rewrite. That is the difference between a program for one station and a
// program other people can use.
package rig

import (
	"errors"
	"fmt"
	"math/rand"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Snapshot is what the panel draws. Everything the operator sees comes from here
// and nothing is inferred by the client.
//
// ⚠️ THE FIELD NAMES ARE THE C++ HOST'S, EXACTLY, AND THAT IS THE WHOLE POINT.
// The Qt client already exists on Windows, macOS, Linux and iOS - signed,
// packaged, with working audio, PTT and a transmit watchdog - and it speaks a
// fixed set of 19 routes and two sockets. Matching that surface means those apps
// connect to THIS host with nothing to rebuild, which is a better answer to
// "we need real desktop apps" than writing new ones.
//
// So a field renamed here is a client broken there. This struct is a contract.
type Snapshot struct {
	Connected   bool   `json:"connected"`
	Freq        int64  `json:"freq"`
	Mode        string `json:"mode"`
	VFO         string `json:"vfo"`
	PowerW      int    `json:"power"`
	TX          bool   `json:"tx"`
	SMeterRaw   int    `json:"s_meter"`
	SWRRaw      int    `json:"swr"`
	ALCRaw      int    `json:"alc"`
	PowerMtrRaw int    `json:"power_mtr"`
	FreqB       int64  `json:"freq_b"`
	Split       bool   `json:"split"`
	TxTimeout   int    `json:"tx_timeout_in"`
	FreqBuf     string `json:"freq_buffer"`
	VFOLocked   bool   `json:"vfo_locked"`
	// ⚠️ THE RECEIVER SETTINGS THE OPERATOR CAN SEE ON THE RIG'S OWN FRONT PANEL.
	// Ported from the C++ host, which carries them for a reason: a noise blanker
	// that is on and a panel that cannot say so is how an operator spends ten
	// minutes wondering why a signal sounds wrong.
	NB        bool `json:"nb"`
	NR        bool `json:"nr"`
	Att       int  `json:"att"`
	XIT       bool `json:"xit"`
	Muted     bool `json:"muted"`
	Diversity bool `json:"diversity"`
	AmpTuning bool `json:"amp_tuning"`
	TgxlTune  bool `json:"tgxl_tuning"`
	// ⚠️ How old this reading is. The C++ host learned the hard way that a stale
	// cache looks exactly like a live one; the age travels WITH the data so a
	// client cannot forget to ask.
	CacheAgeMS int64 `json:"cache_age_ms"`
	Stale      bool  `json:"stale"`
}

// ErrNotSupported is how a radio says it cannot do something.
//
// ⚠️ IT IS A REFUSAL, NOT A FAKE SUCCESS. The rule this preserves is the one the
// old asRig2() adapter was written for: "giving the simulator a fake that
// returns success would let a test pass on a path that cannot exist." Returning
// this instead keeps that honesty AND lets the route exist and explain itself,
// where a missing method made the whole route vanish and the caller guess.
var ErrNotSupported = errors.New("this radio does not support that")

// Rig is any radio. A simulator, a serial port, or a model nobody here owns.
//
// ⚠️ THIS INTERFACE IS THE WHOLE CONTRACT NOW. It used to have five methods
// while *Serial had twenty, so every capability beyond the five was fetched with
// a RUNTIME TYPE ASSERTION - seven of them across four files, two of which were
// the same anonymous interface written out twice. That is what forced main.go to
// carry three separate adapters to narrow one object, one of them existing only
// to stop a typed nil in an interface taking the host down on the first click of
// a button the host does not have.
//
// A capability a radio lacks returns ErrNotSupported. It does not disappear.
type Rig interface {
	Snapshot() Snapshot
	SetFreq(hz int64) error
	SetMode(mode string) error
	SetPTT(on bool) error
	Describe() string

	// Raw CAT. Every radio here can do both; a model that cannot returns
	// ErrNotSupported rather than making the rig-control routes vanish.
	Send(cmd string) error
	Ask(query string) (string, error)

	// Receiver mute, remembered so unmuting restores the operator's own AF.
	SetMuted(on bool) error

	// ⚠️ TRANSMIT ROUTING - which input the radio listens to. Only a real serial
	// rig can do this; the simulator refuses, because a host that says it routed
	// the microphone when it did not is how an operator finds out on the air.
	SetRemoteTX(on bool) error
	RemoteTXState() (rear bool, usb bool, err error)
}

// Sim is a radio that is not there, and says so in Describe().
//
// ⚠️ IT NEVER PRETENDS TO BE REAL. The C++ host has a rule about this: a host
// that reports a rig it cannot reach is worse than one that refuses to start.
type Sim struct {
	mu       sync.RWMutex
	snap     Snapshot
	seed     *rand.Rand
	settings map[string]string
}

func NewSim() *Sim {
	s := &Sim{seed: rand.New(rand.NewSource(time.Now().UnixNano())),
		settings: map[string]string{}}
	s.snap = Snapshot{
		Connected: true, Freq: 7195000, Mode: "LSB", VFO: "A", PowerW: 100,
	}
	go s.drift()
	return s
}

// A band that moves, so a panel drawn against it looks alive rather than frozen -
// and so a client that has stopped polling is obvious.
func (s *Sim) drift() {
	t := time.NewTicker(250 * time.Millisecond)
	for range t.C {
		s.mu.Lock()
		if s.snap.TX {
			s.snap.SMeterRaw = 0
			s.snap.ALCRaw = 30 + s.seed.Intn(12)
			s.snap.SWRRaw = 12 + s.seed.Intn(6)
		} else {
			s.snap.SMeterRaw = 90 + s.seed.Intn(60)
			s.snap.ALCRaw, s.snap.SWRRaw = 0, 0
		}
		s.mu.Unlock()
	}
}

func (s *Sim) Snapshot() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := s.snap
	out.CacheAgeMS = 0 // a simulator has no poll behind it, and says 0 rather than inventing one
	return out
}

func (s *Sim) SetFreq(hz int64) error {
	// ⚠️ Refused rather than clamped. A radio that silently moves you somewhere
	// other than where you asked is worse than one that says no.
	if hz < 1_800_000 || hz > 54_000_000 {
		return fmt.Errorf("%d Hz is outside 1.8-54 MHz", hz)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snap.Freq = hz
	return nil
}

func (s *Sim) SetMode(mode string) error {
	switch mode {
	case "LSB", "USB", "CW", "AM", "FM", "DATA":
	default:
		return fmt.Errorf("unknown mode %q", mode)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snap.Mode = mode
	return nil
}

func (s *Sim) SetPTT(on bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snap.TX = on
	return nil
}

func (s *Sim) Describe() string { return "simulated rig (no radio attached)" }

// ── Raw CAT on the simulator ────────────────────────────────────────────────
//
// ⚠️ THE SIMULATOR TAKES THE SAME COMMANDS THE RADIO DOES. Without this the CAT
// route table could only ever be tested against the live station, which means
// every test of a control route is a transmission or a change to a radio
// somebody is operating. A simulator that only answers status is a simulator
// that cannot test the half of the API that matters.
func (s *Sim) Send(cmd string) error {
	if len(cmd) < 3 || !strings.HasSuffix(cmd, ";") || strings.Count(cmd, ";") != 1 {
		return fmt.Errorf("%q is not a single CAT command", cmd)
	}
	body := strings.TrimSuffix(cmd, ";")
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case strings.HasPrefix(body, "FB") && len(body) == 11:
		hz, err := strconv.ParseInt(body[2:], 10, 64)
		if err != nil {
			return fmt.Errorf("%q is not a frequency", cmd)
		}
		s.snap.FreqB = hz
	case strings.HasPrefix(body, "FA") && len(body) == 11:
		hz, err := strconv.ParseInt(body[2:], 10, 64)
		if err != nil {
			return fmt.Errorf("%q is not a frequency", cmd)
		}
		s.snap.Freq = hz
	case strings.HasPrefix(body, "MD0") && len(body) == 4:
		for name, code := range simModeCode {
			if code == body[3] {
				s.snap.Mode = name
			}
		}
	case strings.HasPrefix(body, "PC") && len(body) == 5:
		w, err := strconv.Atoi(body[2:])
		if err != nil {
			return fmt.Errorf("%q is not a power", cmd)
		}
		s.snap.PowerW = w
	case body == "TX1":
		s.snap.TX = true
	case body == "TX0":
		s.snap.TX = false
	case body == "SV":
		s.snap.Freq, s.snap.FreqB = s.snap.FreqB, s.snap.Freq
	}
	// Everything else is remembered so it can be read back, which is what the
	// toggle routes need. ⚠️ Remembered, not invented: a query for something
	// never set answers 0, and 0 is a real setting.
	// Key by the verb, not by a fixed width: "ST1" is a two-letter verb with one
	// digit, "PA01" is three letters and one digit.
	if len(body) >= 3 {
		s.settings[body[:3]] = body[3:]
	}
	if len(body) >= 2 {
		if _, taken := s.settings[body[:2]]; taken || len(body) == 3 {
			s.settings[body[:2]] = body[2:]
		}
	}
	return nil
}

func (s *Sim) Ask(query string) (string, error) {
	body := strings.TrimSuffix(query, ";")
	s.mu.RLock()
	defer s.mu.RUnlock()
	switch body {
	case "FA":
		return fmt.Sprintf("FA%09d;", s.snap.Freq), nil
	case "FB":
		return fmt.Sprintf("FB%09d;", s.snap.FreqB), nil
	case "PC":
		return fmt.Sprintf("PC%03d;", s.snap.PowerW), nil
	}
	// ⚠️ Two-letter verbs are real verbs. ST; and LK; are queries just as much as
	// PA0; is, and a simulator that only understood three-character prefixes
	// answered "no such command" to them - which made the split and lock routes
	// look broken when the routes were fine and the test double was not.
	if len(body) >= 2 {
		key := body
		if len(body) > 3 {
			key = body[:3]
		}
		if v, ok := s.settings[key]; ok {
			return key + v + ";", nil
		}
		return body + "0;", nil
	}
	return "", fmt.Errorf("the simulated radio has no answer for %q", query)
}

var simModeCode = map[string]byte{
	"LSB": '1', "USB": '2', "CW": '3', "FM": '4', "AM": '5', "DATA": '8',
}

// ⚠️ THE SIMULATOR REFUSES RATHER THAN PRETENDS. These are the capabilities only
// a real serial rig has. Returning nil here would let a test - or an operator -
// believe the microphone had been routed, or the receiver muted, when nothing
// happened at all. A host that reports a rig it cannot reach is worse than one
// that refuses, and the same is true of a capability it does not have.

func (s *Sim) SetMuted(on bool) error { return ErrNotSupported }

func (s *Sim) SetRemoteTX(on bool) error { return ErrNotSupported }

func (s *Sim) RemoteTXState() (bool, bool, error) { return false, false, ErrNotSupported }
