package rig

import (
	"fmt"
	"log"
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
	lastOK   time.Time
	stop     chan struct{}
	pttTimer *time.Timer
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

func (s *Serial) Describe() string { return "serial " + s.name }

// ── Control ─────────────────────────────────────────────────────────────────
//
// ⚠️ WRITES SHARE THE PORT WITH THE POLLER, SO THEY GO THROUGH THE SAME LOCK.
// Two goroutines writing CAT at once interleave two commands into one stream and
// the radio acts on the wreckage - which on a transmitter is not a display glitch.

func (s *Serial) send(cmd string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.port.Write([]byte(cmd))
	return err
}

// SetFreq moves VFO A. ⚠️ Range-checked and REFUSED rather than clamped: a radio
// that silently lands somewhere other than where you asked is worse than one
// that says no.
func (s *Serial) SetFreq(hz int64) error {
	if hz < 1_800_000 || hz > 54_000_000 {
		return fmt.Errorf("%d Hz is outside 1.8-54 MHz", hz)
	}
	return s.send(fmt.Sprintf("FA%09d;", hz))
}

var codeByMode = map[string]byte{
	"LSB": '1', "USB": '2', "CW": '3', "FM": '4', "AM": '5', "DATA": '8',
}

func (s *Serial) SetMode(mode string) error {
	code, ok := codeByMode[strings.ToUpper(mode)]
	if !ok {
		return fmt.Errorf("unknown mode %q", mode)
	}
	return s.send(fmt.Sprintf("MD0%c;", code))
}

// ⚠️ THE TRANSMIT WATCHDOG, AND IT LIVES HERE BECAUSE HERE IS NEXT TO THE RADIO.
//
// A client-side timeout protects nothing when the client is the thing that died:
// a browser tab closing, a laptop sleeping and a network dropping all look
// identical from the panel, and in every one of them the carrier stays up. So the
// host keys the rig and immediately arms a timer that will unkey it, and only a
// deliberate unkey - or another key press - stops that timer.
var pttTimeout = 180 * time.Second

// SetPTTTimeout makes the watchdog testable. ⚠️ A watchdog that has never fired
// is a watchdog nobody has tested - the whole point is the path nothing takes on
// a good day, and three minutes is too long to sit through to prove it works.
// Refuses zero: "no timeout" is not a configuration, it is the safety removed.
func SetPTTTimeout(d time.Duration) error {
	if d <= 0 {
		return fmt.Errorf("a transmit watchdog of %v is no watchdog at all", d)
	}
	pttTimeout = d
	return nil
}

func (s *Serial) SetPTT(on bool) error {
	s.mu.Lock()
	if s.pttTimer != nil {
		s.pttTimer.Stop()
		s.pttTimer = nil
	}
	s.mu.Unlock()

	if !on {
		return s.send("TX0;")
	}
	if err := s.send("TX1;"); err != nil {
		return err
	}
	s.mu.Lock()
	s.pttTimer = time.AfterFunc(pttTimeout, func() {
		// ⚠️ Unconditional. The poll cache is up to 250 ms old and TX0; to a rig
		// that is already receiving costs nothing - nothing is worth an open
		// carrier.
		_ = s.send("TX0;")
		log.Printf("WATCHDOG: unkeyed after %s - the transmitter had been on that long", pttTimeout)
	})
	s.mu.Unlock()
	return nil
}

// ── The audio path INSIDE the radio ─────────────────────────────────────────
//
// ⚠️ ON MIC, THE RADIO IGNORES THE USB CODEC COMPLETELY. It keys, ALC sits at its
// idle floor, power stays 0, and every counter in the audio chain reads perfectly
// healthy - so a station can be "transmitting" and putting out nothing while
// nothing anywhere reports a fault. The C++ host lost hours to exactly this, and
// then lost an evening more because NOTHING set REAR back after a disconnect.
//
// ⚠️ AND IT IS A TWO-SIDED TRAP. Left on REAR, the operator's own hand mic at the
// radio does nothing. Whatever sets this must put it back.
//
// ⚠️ 50 ms BETWEEN MENU WRITES. Sent back to back the rig takes the first and
// ignores the rest, SILENTLY. The reference host has these sleeps and nobody
// writes those for fun.
func (s *Serial) SetRemoteTX(on bool) error {
	if on {
		if err := s.send("EX0101111;"); err != nil { // MOD SOURCE -> REAR
			return err
		}
		time.Sleep(50 * time.Millisecond)
		if err := s.send("EX0101121;"); err != nil { // REAR SELECT -> USB
			return err
		}
		time.Sleep(50 * time.Millisecond)
		return s.send("EX010113050;") // RPORT GAIN
	}
	return s.send("EX0101110;") // MOD SOURCE -> MIC
}

// RemoteTXState asks the RADIO what it is set to, rather than reporting what was
// sent. ⚠️ "Commands were written" is not "the rig took them" - and a confident
// wrong answer here sends the search for a dead transmitter to the wrong end of
// the chain, which is precisely how the C++ host wasted an evening.
func (s *Serial) RemoteTXState() (rear bool, usb bool, err error) {
	r1, err := s.ask("EX010111;")
	if err != nil {
		return false, false, err
	}
	r2, err := s.ask("EX010112;")
	if err != nil {
		return false, false, err
	}
	// The reply echoes the menu number and ends with the value.
	rear = len(r1) > 0 && r1[len(r1)-1] == '1'
	usb = len(r2) > 0 && r2[len(r2)-1] == '1'
	return rear, usb, nil
}

// Unkey is called when the last client goes away. ⚠️ A dropped link must not
// leave a carrier up, and a crash, a clean quit and a dead network are
// indistinguishable from here - so all three end the same way.
func (s *Serial) Unkey() {
	_ = s.SetPTT(false)
}
