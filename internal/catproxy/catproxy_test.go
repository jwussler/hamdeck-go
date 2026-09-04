package catproxy

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRig records what reached the radio and answers queries.
type fakeRig struct {
	mu   sync.Mutex
	sent []string
	askd []string
}

func (f *fakeRig) Send(c string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, c)
	return nil
}

func (f *fakeRig) Ask(c string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.askd = append(f.askd, c)
	switch c {
	case "FA;":
		return "FA014200000;", nil
	case "MD0;":
		return "MD02;", nil
	}
	return "", fmt.Errorf("no answer")
}

func (f *fakeRig) snapshot() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.sent...), append([]string(nil), f.askd...)
}

func dial(t *testing.T, p *Proxy) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", p.Port()))
	if err != nil {
		t.Fatalf("could not connect to the proxy: %v", err)
	}
	return c
}

func start(t *testing.T, rig Rig) *Proxy {
	t.Helper()
	// Port 0 lets the OS choose, so tests never collide with a real proxy.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	p := New(port, rig)
	if err := p.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	t.Cleanup(func() { p.Close() })
	return p
}

func TestQueryGetsTheRadiosAnswer(t *testing.T) {
	rig := &fakeRig{}
	p := start(t, rig)
	c := dial(t, p)
	defer c.Close()

	c.Write([]byte("FA;"))
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 64)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatalf("no reply to FA;: %v", err)
	}
	if got := string(buf[:n]); got != "FA014200000;" {
		t.Fatalf("got %q, want the radio's own answer", got)
	}
}

// ⚠️ THE STALL TEST. A set answers nothing; if the proxy waits for a reply, a
// logger polling several times a second backs the whole CAT queue up behind
// commands that were never going to answer. So a set must produce no reply AND
// must not delay the next query.
func TestSetProducesNoReplyAndDoesNotStall(t *testing.T) {
	rig := &fakeRig{}
	p := start(t, rig)
	c := dial(t, p)
	defer c.Close()

	c.Write([]byte("FA014200000;FA;"))
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 64)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatalf("the query after a set never answered: %v", err)
	}
	if got := string(buf[:n]); got != "FA014200000;" {
		t.Fatalf("got %q - the set must not produce a reply of its own", got)
	}
	sent, asked := rig.snapshot()
	if len(sent) != 1 || sent[0] != "FA014200000;" {
		t.Fatalf("the set did not reach the radio: %v", sent)
	}
	if len(asked) != 1 || asked[0] != "FA;" {
		t.Fatalf("the query did not reach the radio: %v", asked)
	}
}

// ⚠️ TCP SPLITS WHEREVER IT LIKES. A logger writing three commands can arrive as
// one read or as six, and a parser that trusts read boundaries works perfectly
// on a fast loopback and falls apart over anything slower.
func TestCommandsSplitAcrossReads(t *testing.T) {
	rig := &fakeRig{}
	p := start(t, rig)
	c := dial(t, p)
	defer c.Close()

	for _, chunk := range []string{"F", "A", ";", "MD", "0;"} {
		c.Write([]byte(chunk))
		time.Sleep(20 * time.Millisecond)
	}
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	var got strings.Builder
	buf := make([]byte, 64)
	for got.Len() < len("FA014200000;MD02;") {
		n, err := c.Read(buf)
		if err != nil {
			break
		}
		got.Write(buf[:n])
	}
	if got.String() != "FA014200000;MD02;" {
		t.Fatalf("got %q, want both answers in order", got.String())
	}
}

// ⚠️ NEVER INVENT A REPLY. A logger handed a made-up frequency writes it into the
// log; one handed nothing retries.
func TestUnanswerableQueryReturnsSilence(t *testing.T) {
	rig := &fakeRig{}
	p := start(t, rig)
	c := dial(t, p)
	defer c.Close()

	c.Write([]byte("IF;"))
	c.SetReadDeadline(time.Now().Add(400 * time.Millisecond))
	buf := make([]byte, 64)
	if n, err := c.Read(buf); err == nil {
		t.Fatalf("expected silence, got %q", string(buf[:n]))
	}
}

// ⚠️ LOOPBACK ONLY. Anything that reaches this port can key the transmitter, so
// binding beyond 127.0.0.1 would publish a transmitter with no authentication.
func TestBindsLoopbackOnly(t *testing.T) {
	rig := &fakeRig{}
	p := start(t, rig)
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		t.Skip("cannot enumerate interfaces here")
	}
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() || ipnet.IP.To4() == nil {
			continue
		}
		c, err := net.DialTimeout("tcp",
			fmt.Sprintf("%s:%d", ipnet.IP.String(), p.Port()), 700*time.Millisecond)
		if err == nil {
			c.Close()
			t.Fatalf("the CAT proxy accepted a connection on %s - it must be loopback only",
				ipnet.IP)
		}
	}
}

func TestIsQueryDistinguishesSetFromAsk(t *testing.T) {
	for _, c := range []string{"FA;", "MD0;", "TX;", "RM6;"} {
		if !isQuery(c) {
			t.Fatalf("%s is a query and was treated as a set", c)
		}
	}
	for _, c := range []string{"FA014200000;", "MD02;", "TX1;", "PC100;"} {
		if isQuery(c) {
			t.Fatalf("%s is a set and was treated as a query - it would stall", c)
		}
	}
}
