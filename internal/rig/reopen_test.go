package rig

import (
	"errors"
	"sync"
	"testing"
	"time"

	"go.bug.st/serial"
)

// ⚠️ THE FIRST TEST IN THIS PACKAGE, and it is here because rig control had the
// same failure the receive audio had: a device that stops answering and is never
// reopened. Connected goes false within 3 s so the panel can SEE it, but the
// host does not exit - so systemd's Restart=on-failure never fires - and a
// device-bound restart only helps when the device NODE disappears. An I/O error
// that leaves the node in place left the radio unreachable until a human
// restarted the service.

type deadPort struct {
	mu     sync.Mutex
	closed bool
}

func (p *deadPort) Read([]byte) (int, error)                             { return 0, errors.New("input/output error") }
func (p *deadPort) Write([]byte) (int, error)                            { return 0, errors.New("input/output error") }
func (p *deadPort) Close() error                                         { p.mu.Lock(); p.closed = true; p.mu.Unlock(); return nil }
func (p *deadPort) SetMode(*serial.Mode) error                           { return nil }
func (p *deadPort) SetDTR(bool) error                                    { return nil }
func (p *deadPort) SetRTS(bool) error                                    { return nil }
func (p *deadPort) GetModemStatusBits() (*serial.ModemStatusBits, error) { return nil, nil }
func (p *deadPort) SetReadTimeout(time.Duration) error                   { return nil }
func (p *deadPort) Drain() error                                         { return nil }
func (p *deadPort) ResetInputBuffer() error                              { return nil }
func (p *deadPort) ResetOutputBuffer() error                             { return nil }
func (p *deadPort) Break(time.Duration) error                            { return nil }

// A port that has gone silent is closed and opened again.
func TestSerialReopensAfterTheRadioGoesSilent(t *testing.T) {
	old := &deadPort{}
	var opened int
	var mu sync.Mutex

	s := &Serial{
		port: old, name: "/dev/ttyTEST", dev: "/dev/ttyTEST", baud: 38400,
		stop: make(chan struct{}),
		openPort: func(string, int) (serial.Port, error) {
			mu.Lock()
			opened++
			mu.Unlock()
			return &deadPort{}, nil
		},
	}
	// Silent for far longer than deadPolls allows.
	s.lastOK = time.Now().Add(-1 * time.Minute)

	s.reopenIfDead()

	mu.Lock()
	n := opened
	mu.Unlock()
	if n != 1 {
		t.Fatalf("a silent port was not reopened: opener called %d time(s)", n)
	}
	old.mu.Lock()
	closed := old.closed
	old.mu.Unlock()
	if !closed {
		t.Fatal("the dead port was replaced without being closed - that leaks the fd, " +
			"and a held fd on a deleted device node is what renames the port on replug")
	}
	if s.reopens != 1 {
		t.Fatalf("the reopen was not recorded: reopens=%d", s.reopens)
	}
}

// ⚠️ A radio that answered recently must NOT be dropped. A reopen on every
// hiccup would take the port down mid-QSO for a missed cycle.
func TestSerialDoesNotReopenARadioThatIsAnswering(t *testing.T) {
	var opened int
	s := &Serial{
		port: &deadPort{}, name: "/dev/ttyTEST", dev: "/dev/ttyTEST", baud: 38400,
		stop: make(chan struct{}),
		openPort: func(string, int) (serial.Port, error) {
			opened++
			return &deadPort{}, nil
		},
	}
	s.lastOK = time.Now() // it just answered
	s.reopenIfDead()
	if opened != 0 {
		t.Fatalf("a live port was reopened %d time(s) - that drops the radio mid-QSO", opened)
	}
}
