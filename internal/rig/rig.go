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
	"fmt"
	"math/rand"
	"sync"
	"time"
)

// Snapshot is what the panel draws. Everything the operator sees comes from here
// and nothing is inferred by the client.
type Snapshot struct {
	Connected bool   `json:"connected"`
	Freq      int64  `json:"freq"`
	Mode      string `json:"mode"`
	VFO       string `json:"vfo"`
	PowerW    int    `json:"power"`
	TX        bool   `json:"tx"`
	SMeterRaw int    `json:"s_meter"`
	SWRRaw    int    `json:"swr"`
	ALCRaw    int    `json:"alc"`
	// ⚠️ How old this reading is. The C++ host learned the hard way that a stale
	// cache looks exactly like a live one; the age travels WITH the data so a
	// client cannot forget to ask.
	CacheAgeMS int64 `json:"cache_age_ms"`
	Stale      bool  `json:"stale"`
}

// Rig is any radio. A simulator, a serial port, or a model nobody here owns.
type Rig interface {
	Snapshot() Snapshot
	SetFreq(hz int64) error
	SetMode(mode string) error
	SetPTT(on bool) error
	Describe() string
}

// Sim is a radio that is not there, and says so in Describe().
//
// ⚠️ IT NEVER PRETENDS TO BE REAL. The C++ host has a rule about this: a host
// that reports a rig it cannot reach is worse than one that refuses to start.
type Sim struct {
	mu   sync.RWMutex
	snap Snapshot
	seed *rand.Rand
}

func NewSim() *Sim {
	s := &Sim{seed: rand.New(rand.NewSource(time.Now().UnixNano()))}
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
