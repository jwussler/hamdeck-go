// Package catproxy lets other software talk CAT to the radio through this host.
//
// ⚠️ THIS IS THE BIGGEST REAL GAP IN REMOTE OPERATING. One program can hold a
// serial port. Yaesu's SCU-LAN10 takes the radio's USB and offers no virtual COM
// port and no CAT passthrough - its manual says outright that it does not support
// digital modes such as RTTY - so the moment you go remote, your logger, WSJT-X
// and contest software all stop working. The same is true of this host: while it
// holds /dev/ttyRIG, nothing else can have it.
//
// Without this, running a logger alongside HamDeck means a virtual serial-port
// splitter (VSPE, com0com): a second thing to install, a second thing to
// configure, and a second thing to go wrong on a contest morning.
//
//	N1MM:   Configure Ports -> Port = TCP -> Host 127.0.0.1, Port 4532
//	Others: anything that speaks raw CAT to a TCP socket
//
// ⚠️ LOOPBACK ONLY, AND THAT IS THE WHOLE SECURITY MODEL. It forwards CAT
// verbatim, including TX1; - anything that reaches this port can key the
// transmitter. It is deliberately not filtered, because a logger legitimately
// needs to key the rig for CW and PTT. It must never bind 0.0.0.0; if it has to
// be reachable from another machine, that is a tunnel, not a bind.
package catproxy

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
)

// Rig is the slice of the radio this needs.
//
// ⚠️ Ask and Send only, so the proxy goes through the SAME serialised exchange
// everything else does. Two writers on one serial line interleave and the
// replies land against whichever reader asked first - not a crash, just a
// frequency readout that is quietly wrong.
type Rig interface {
	Ask(string) (string, error)
	Send(string) error
}

// queries are the CAT verbs that PRODUCE A REPLY.
//
// ⚠️ A "set" answers nothing, so waiting for a reply to one blocks until the
// read times out - and a logger polling frequency several times a second stalls
// the whole CAT queue behind commands that were never going to answer. This list
// is transcribed, not inferred: verbs guessed from their neighbours have been
// wrong before.
var queries = map[string]bool{}

func init() {
	for _, q := range strings.Fields(`FA FB IF MD0 TX PC ST FT VS AG0 AG1 RG0
		SM0 SM1 RM0 RM1 RM2 RM3 RM4 RM5 RM6 RM7 RM8 RM9 PA0 RA0 GT0 NB0 NR0
		BC0 RT XT RD VX PR PR0 PR1 LK AN0 KS BI ID`) {
		queries[q] = true
	}
}

// isQuery decides whether to wait for a reply.
//
// ⚠️ A query is the BARE verb: "FA;" asks, "FA014200000;" sets. Treating a set as
// a query is the stall above; treating a query as a set loses the answer the
// logger is waiting for, and it retries forever.
func isQuery(cmd string) bool {
	return queries[strings.TrimSuffix(cmd, ";")]
}

type Proxy struct {
	port int
	rig  Rig

	mu       sync.Mutex
	ln       net.Listener
	clients  int
	commands int64
}

func New(port int, rig Rig) *Proxy { return &Proxy{port: port, rig: rig} }

func (p *Proxy) Port() int { return p.port }

func (p *Proxy) Describe() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ln == nil {
		return "not running"
	}
	return fmt.Sprintf("127.0.0.1:%d - %d connected, %d commands", p.port, p.clients, p.commands)
}

func (p *Proxy) Stats() (clients int, commands int64, running bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.clients, p.commands, p.ln != nil
}

func (p *Proxy) Start() error {
	// ⚠️ 127.0.0.1 EXPLICITLY, never ":port". Binding all interfaces publishes a
	// transmitter to the network with no authentication whatsoever.
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p.port))
	if err != nil {
		return fmt.Errorf("CAT proxy could not bind 127.0.0.1:%d: %w", p.port, err)
	}
	p.mu.Lock()
	p.ln = ln
	p.mu.Unlock()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go p.serve(c)
		}
	}()
	return nil
}

func (p *Proxy) Close() error {
	p.mu.Lock()
	ln := p.ln
	p.ln = nil
	p.mu.Unlock()
	if ln == nil {
		return nil
	}
	return ln.Close()
}

func (p *Proxy) serve(c net.Conn) {
	defer c.Close()
	p.mu.Lock()
	p.clients++
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.clients--
		p.mu.Unlock()
	}()
	log.Printf("cat-proxy: %s connected", c.RemoteAddr())

	var buf []byte
	tmp := make([]byte, 256)
	for {
		n, err := c.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			// ⚠️ SPLIT ON THE SEMICOLON. CAT has no line endings, a logger sends
			// several commands in one write, and TCP splits them wherever it
			// likes - so a read boundary means nothing.
			for {
				i := bytes.IndexByte(buf, ';')
				if i < 0 {
					break
				}
				cmd := string(buf[:i+1])
				buf = buf[i+1:]
				if reply := p.handle(cmd); reply != "" {
					if _, werr := c.Write([]byte(reply)); werr != nil {
						return
					}
				}
			}
			if len(buf) > 128 {
				log.Printf("cat-proxy: %s sent 128 bytes with no terminator - not CAT, dropping",
					c.RemoteAddr())
				return
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("cat-proxy: %s: %v", c.RemoteAddr(), err)
			}
			log.Printf("cat-proxy: %s disconnected", c.RemoteAddr())
			return
		}
	}
}

func (p *Proxy) handle(cmd string) string {
	p.mu.Lock()
	p.commands++
	p.mu.Unlock()

	if !isQuery(cmd) {
		if err := p.rig.Send(cmd); err != nil {
			log.Printf("cat-proxy: the radio refused %q: %v", cmd, err)
		}
		// ⚠️ NOTHING IS RETURNED for a set, because the radio returns nothing.
		// An invented acknowledgement makes a rejected command look accepted.
		return ""
	}
	reply, err := p.rig.Ask(cmd)
	if err != nil {
		log.Printf("cat-proxy: no answer to %q: %v", cmd, err)
		// ⚠️ Silence, never a plausible reply. A logger handed an invented
		// frequency writes it into the log; one handed nothing retries.
		return ""
	}
	if !strings.HasSuffix(reply, ";") {
		reply += ";"
	}
	return reply
}
