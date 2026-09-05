package audio

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// ⚠️ THIS IS THE GATE FOR A BUG THAT WENT UNNOTICED TWICE IN TWO DAYS. ALSA
// capture threw an I/O error out of the station's USB codec, the read loop
// logged it once and returned, and the host carried on answering every route,
// metering, tuning and transmitting while the operator heard nothing and was
// told nothing. A recovery path nobody has watched recover is a hope, not a fix.
type flakyDev struct {
	mu     sync.Mutex
	reads  int
	failAt int // fail the read at this count, then never again for this device
	closed bool
}

func (d *flakyDev) Read(b []byte) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.reads++
	if d.failAt > 0 && d.reads >= d.failAt {
		return errors.New("ioctl read (24 bytes) 0x4151 failed: input/output error")
	}
	time.Sleep(time.Millisecond)
	return nil
}

func (d *flakyDev) Close() {
	d.mu.Lock()
	d.closed = true
	d.mu.Unlock()
}

// The capture fails like the real codec does, and the stream must open it again.
func TestCaptureReopensAfterIOError(t *testing.T) {
	var mu sync.Mutex
	opened := 0

	s := NewStream()
	s.open = func(match string, want int) (captureDev, int, int, int, int, error) {
		mu.Lock()
		defer mu.Unlock()
		opened++
		// The first device dies after a few reads, like the codec did. Every
		// device after it is healthy - the fault is transient, which is exactly
		// why giving up on it was the wrong answer.
		fail := 0
		if opened == 1 {
			fail = 3
		}
		return &flakyDev{failAt: fail}, 22050, 1, 512, 2, nil
	}
	defer s.Stop()

	if err := s.StartSized("", 0); err != nil {
		t.Fatalf("start: %v", err)
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := opened
		mu.Unlock()
		if n >= 2 && s.Describe() != "not started" && s.Running() {
			return // reopened and healthy again
		}
		time.Sleep(50 * time.Millisecond)
	}
	mu.Lock()
	n := opened
	mu.Unlock()
	t.Fatalf("capture never reopened after an I/O error: opened %d time(s), state %q", n, s.Describe())
}

// While it is down the panel must be TOLD, not shown a healthy-looking stream.
func TestCaptureSaysWhenItIsDown(t *testing.T) {
	s := NewStream()
	s.open = func(match string, want int) (captureDev, int, int, int, int, error) {
		return nil, 0, 0, 0, 0, errors.New("no such device")
	}
	defer s.Stop()
	s.mu.Lock()
	s.lastErr = errors.New("input/output error")
	s.failures = 2
	s.running = false
	s.mu.Unlock()
	got := s.Describe()
	if got == "not started" || got == "" {
		t.Fatalf("a down capture described itself as %q - the operator gets no clue", got)
	}
}
