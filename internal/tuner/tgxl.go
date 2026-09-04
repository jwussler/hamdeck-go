// Package tuner drives the TG-XL antenna tuner over TCP.
//
// ⚠️ THIS IS A DIFFERENT BOX FROM THE RIG'S INTERNAL ATU (/api/tune, "AC002;").
// They are kept separate and each names itself in its reply, so a confirmation
// can never just say "tuning" and leave the operator guessing which thing is
// about to key up.
//
// ⚠️ THE TUNER NEEDS A CARRIER - THAT IS THE WHOLE SEQUENCE. Sending autotune
// while the transmitter is idle tunes nothing: the tuner has no RF to measure
// and the operator sees a button that does nothing.
//
//	1  save the current power and mode
//	2  set 15 W, set CW
//	3  connect TCP, 3 s timeout
//	4  key the transmitter, settle
//	5  send "C1|autotune"
//	6  poll "C1|status", watch tuning go 1 then 0
//	7  unkey, then restore the saved power and mode
//
// ⚠️ 3 BEFORE 4 IS DELIBERATE and the reference host has them the other way
// round. Keying first means a tuner that is switched off gets 15 W into the
// antenna for the whole 3 s connect timeout, tuning nothing. The tuner only
// needs the carrier from step 5 onwards, so connecting first costs nothing and
// an unreachable tuner now produces no RF at all.
//
// ⚠️ 4 AND 7 ARE A PAIR AND 7 MUST HAPPEN ON EVERY PATH OUT - timeout, refused
// connection, error, operator stop. A tuner that leaves the rig keyed at 15 W in
// CW is worse than one that does not tune.
package tuner

import (
	"bufio"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

const (
	connectTimeout = 3 * time.Second
	readTimeout    = 2 * time.Second
	overallLimit   = 45 * time.Second
	// ⚠️ COMPLETION IS "tuning WENT 1 THEN 0", NOT "tuning IS 0". The tuner
	// emits 0,1,0 within milliseconds of connecting; a real tune takes 3-15 s.
	ignoreEarly    = 2 * time.Second
	noStartGiveUp  = 5 * time.Second
	tunePowerWatts = 15
	settle         = 400 * time.Millisecond
)

// Radio is what the tuner needs from the rig. Deliberately small: the tuner has
// no business doing anything else to the radio.
type Radio interface {
	Snapshot() (powerW int, mode string)
	SetPower(w int) error
	SetMode(mode string) error
	SetPTT(on bool) error
}

type TGXL struct {
	host string
	port int
	rig  Radio

	mu      sync.Mutex
	active  bool
	stop    bool
	lastMsg string
}

func New(host string, port int, rig Radio) *TGXL {
	return &TGXL{host: host, port: port, rig: rig}
}

func (t *TGXL) Configured() bool { return t.host != "" }

func (t *TGXL) Describe() string {
	if !t.Configured() {
		return "no tuner configured"
	}
	return fmt.Sprintf("tgxl %s:%d", t.host, t.port)
}

func (t *TGXL) Active() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.active
}

func (t *TGXL) Message() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.lastMsg
}

// Stop asks a running tune to give up. The unkey happens on the way out, as it
// does for every other exit path.
func (t *TGXL) Stop() {
	t.mu.Lock()
	t.stop = true
	t.mu.Unlock()
}

// Tune runs the whole sequence. It blocks; the caller decides whether to wait.
func (t *TGXL) Tune() error {
	if !t.Configured() {
		return fmt.Errorf("TGXL is not configured - set the tuner host")
	}
	t.mu.Lock()
	if t.active {
		t.mu.Unlock()
		return fmt.Errorf("a tune is already running")
	}
	t.active, t.stop = true, false
	t.lastMsg = fmt.Sprintf("keying %d W CW and tuning", tunePowerWatts)
	t.mu.Unlock()

	// 1 - remember what to put back.
	savedPower, savedMode := t.rig.Snapshot()

	keyed := false
	// ⚠️ THE RESTORE. Every return below passes through here, including the
	// panicking one: unkey FIRST, then hand the radio back the way it was.
	defer func() {
		if keyed {
			_ = t.rig.SetPTT(false)
			time.Sleep(settle)
		}
		if savedMode != "" {
			_ = t.rig.SetMode(savedMode)
			time.Sleep(settle)
		}
		if savedPower > 0 {
			_ = t.rig.SetPower(savedPower)
		}
		t.mu.Lock()
		t.active = false
		t.mu.Unlock()
	}()

	// 2 - low power, CW.
	if err := t.rig.SetPower(tunePowerWatts); err != nil {
		return fmt.Errorf("could not set tune power: %w", err)
	}
	time.Sleep(settle)
	if err := t.rig.SetMode("CW"); err != nil {
		return fmt.Errorf("could not set CW: %w", err)
	}
	time.Sleep(settle)

	// 3 - connect BEFORE keying.
	addr := net.JoinHostPort(t.host, fmt.Sprint(t.port))
	conn, err := net.DialTimeout("tcp", addr, connectTimeout)
	if err != nil {
		t.setMsg("no answer from " + addr)
		return fmt.Errorf("no answer from %s: %w", addr, err)
	}
	defer conn.Close()

	// 4 - now there is somewhere for the carrier to be measured.
	if err := t.rig.SetPTT(true); err != nil {
		return fmt.Errorf("could not key the transmitter: %w", err)
	}
	keyed = true
	time.Sleep(settle)

	// 5 - autotune.
	if _, err := conn.Write([]byte("C1|autotune\n")); err != nil {
		return fmt.Errorf("could not send autotune: %w", err)
	}

	// 6 - watch tuning go 1 then 0.
	start := time.Now()
	seenTuning := false
	rd := bufio.NewReader(conn)
	for time.Since(start) < overallLimit {
		t.mu.Lock()
		stopped := t.stop
		t.mu.Unlock()
		if stopped {
			t.setMsg("stopped by the operator")
			return nil
		}
		if _, err := conn.Write([]byte("C1|status\n")); err != nil {
			return fmt.Errorf("the tuner stopped answering: %w", err)
		}
		conn.SetReadDeadline(time.Now().Add(readTimeout))
		line, err := rd.ReadString('\n')
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return fmt.Errorf("the tuner closed the connection")
		}
		line = strings.TrimSpace(line)
		// The firmware banner ("V1.2.17") carries no state.
		if line == "" || strings.HasPrefix(line, "V") {
			continue
		}
		at := strings.Index(line, "tuning=")
		if at < 0 {
			continue
		}
		switch line[at+7] {
		case '1':
			seenTuning = true
		case '0':
			elapsed := time.Since(start)
			if seenTuning && elapsed >= ignoreEarly {
				t.setMsg(fmt.Sprintf("tuned in %.1f s", elapsed.Seconds()))
				return nil // the real 1 -> 0
			}
			if seenTuning {
				// Inside the ignore window: this is the connect burst, not a
				// tune. DISARM and keep waiting for the real one.
				seenTuning = false
				continue
			}
			if elapsed > noStartGiveUp {
				// Never started. Stop keying regardless - holding a carrier
				// into a tuner that is not tuning helps nobody.
				t.setMsg("the tuner never started tuning - giving up")
				return fmt.Errorf("the tuner never started tuning")
			}
		}
	}
	t.setMsg("the tune did not finish within 45 s")
	return fmt.Errorf("the tune did not finish within 45 s")
}

func (t *TGXL) setMsg(m string) {
	t.mu.Lock()
	t.lastMsg = m
	t.mu.Unlock()
}
