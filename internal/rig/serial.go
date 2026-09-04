package rig

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.bug.st/serial"
)

// Serial is a real radio on a real port.
//
// ⚠️ READ-ONLY, DELIBERATELY, AND IT REFUSES TO TRANSMIT.
//
// This host has no transmit watchdog yet. The rule the C++ host earned the hard
// way is that the thing which stops a stuck carrier lives NEXT TO THE RADIO, and
// until that exists here, a route that can key this transmitter would be a
// hazard with a nice API in front of it. SetPTT returns an error saying so
// rather than quietly doing nothing, because a PTT that silently fails is worse
// than one that refuses.
//
// ⚠️ AND IT NEVER PROBES WITH A CONTROL VERB. Everything below asks; nothing
// sets. Reading is safe on a live station, writing is not, and /api/mode on the
// simulator is not the same act as /api/mode on a radio somebody is operating.
type Serial struct {
	mu     sync.RWMutex
	port   serial.Port
	name   string
	snap   Snapshot
	lastOK time.Time
	stop   chan struct{}
}

func OpenSerial(dev string, baud int) (*Serial, error) {
	p, err := serial.Open(dev, &serial.Mode{BaudRate: baud})
	if err != nil {
		return nil, fmt.Errorf("could not open %s: %w", dev, err)
	}
	// ⚠️ A read timeout, or a radio that stops answering hangs the poller
	// forever and the panel shows a frequency that stopped being true.
	p.SetReadTimeout(400 * time.Millisecond)
	s := &Serial{port: p, name: dev, stop: make(chan struct{})}
	s.snap.VFO = "A"
	go s.pollLoop()
	return s, nil
}

func (s *Serial) Close() { close(s.stop); s.port.Close() }

// ask sends one CAT command and reads until the terminating semicolon.
func (s *Serial) ask(cmd string) (string, error) {
	if _, err := s.port.Write([]byte(cmd)); err != nil {
		return "", err
	}
	buf := make([]byte, 0, 64)
	one := make([]byte, 1)
	deadline := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(deadline) {
		n, err := s.port.Read(one)
		if err != nil {
			return "", err
		}
		if n == 0 {
			continue
		}
		if one[0] == ';' {
			return string(buf), nil
		}
		buf = append(buf, one[0])
		if len(buf) > 64 {
			// ⚠️ A reply longer than any real one means the stream is out of
			// step. Give up rather than return a slice of two answers glued
			// together, which parses into a plausible wrong number.
			return "", fmt.Errorf("runaway reply to %q", cmd)
		}
	}
	return "", fmt.Errorf("no answer to %q", cmd)
}

var modeByCode = map[byte]string{
	'1': "LSB", '2': "USB", '3': "CW", '4': "FM", '5': "AM", '8': "DATA", 'C': "DATA",
}

func (s *Serial) pollLoop() {
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			s.pollOnce()
		}
	}
}

// ⚠️ THE VERB TABLE, WITH ITS OFFSETS, TAKEN FROM A HOST THAT HAS BEEN ON THE AIR
// RATHER THAN FROM A MANUAL. Every one of these is a fixed-width reply and the
// widths are NOT uniform - SM0 answers three digits, FA answers nine - and a
// guess costs a reading that silently stays zero. The S-meter did exactly that
// here: parsed as four digits, every reply failed the length check, and the
// panel showed a flat 0 on a live 40 m band while the audio probe measured 23%.
//
// This table is also the reason a rig DRIVER exists: another model answers the
// same questions at different offsets, and that is a table to fill in rather
// than a parser to rewrite.
func (s *Serial) pollOnce() {
	freq, ferr := s.ask("FA;")   // VFO A frequency, 9 digits at offset 2
	mode, merr := s.ask("MD0;")  // mode code, 1 char at offset 3
	smtr, serr := s.ask("SM0;")  // S-meter, 3 digits at offset 3
	pwr, perr := s.ask("PC;")    // power setting, 3 digits at offset 2
	tx, terr := s.ask("TX;")     // transmit flag, 1 char at offset 2

	s.mu.Lock()
	defer s.mu.Unlock()

	// ⚠️ A FAILED READ LEAVES THE OLD VALUE AND LETS IT GO STALE. It does not
	// zero the frequency and it does not invent one: the C++ host's own scar is
	// a status route that returned a plausible value and sent an evening of
	// debugging to the wrong end of the chain.
	ok := false
	if ferr == nil && strings.HasPrefix(freq, "FA") && len(freq) >= 11 {
		if hz, err := strconv.ParseInt(strings.TrimLeft(freq[2:11], "0"), 10, 64); err == nil {
			s.snap.Freq = hz
			ok = true
		}
	}
	if merr == nil && strings.HasPrefix(mode, "MD0") && len(mode) >= 4 {
		if m, found := modeByCode[mode[3]]; found {
			s.snap.Mode = m
		}
	}
	if serr == nil && strings.HasPrefix(smtr, "SM0") && len(smtr) >= 6 {
		if raw, err := strconv.Atoi(smtr[3:6]); err == nil {
			s.snap.SMeterRaw = raw
		}
	}
	if perr == nil && strings.HasPrefix(pwr, "PC") && len(pwr) >= 5 {
		if w, err := strconv.Atoi(pwr[2:5]); err == nil {
			s.snap.PowerW = w
		}
	}
	// ⚠️ TX;, not the IF block. The transmit flag has its own one-character
	// answer, and reading it out of a long info string means an offset that
	// differs per model - on a transmitter, the reading you most want to be
	// certain of is the one that says whether it is transmitting.
	if terr == nil && strings.HasPrefix(tx, "TX") && len(tx) >= 3 {
		s.snap.TX = tx[2] != '0'
	}
	if ok {
		s.lastOK = time.Now()
	}
	s.snap.Connected = time.Since(s.lastOK) < 3*time.Second
}

func (s *Serial) Snapshot() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := s.snap
	age := time.Since(s.lastOK).Milliseconds()
	if s.lastOK.IsZero() {
		age = -1
	}
	out.CacheAgeMS = age
	// ⚠️ The age travels WITH the reading, so a client cannot forget to ask.
	out.Stale = age < 0 || age > 2000
	return out
}

func (s *Serial) Describe() string { return "serial " + s.name + " (read-only)" }

// ⚠️ EVERY WRITE IS REFUSED, AND SAYS WHY. See the type comment: no watchdog
// here yet, so nothing here may change a transmitter's state.
const readOnly = "this host reads the radio but does not command it yet - " +
	"there is no transmit watchdog on this side, and the watchdog belongs next to the radio"

func (s *Serial) SetFreq(int64) error  { return fmt.Errorf("%s", readOnly) }
func (s *Serial) SetMode(string) error { return fmt.Errorf("%s", readOnly) }
func (s *Serial) SetPTT(bool) error    { return fmt.Errorf("%s", readOnly) }
