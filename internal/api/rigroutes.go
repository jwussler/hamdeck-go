package api

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// The CAT table, ported from the C++ host route by route.
//
// ⚠️ ONE TABLE, NOT SCATTERED HANDLERS. The C++ host keeps its rig routes in one
// generated list for a reason: the moment the same command exists in two places
// they drift, and the drift is silent because both still answer 200.
//
// ⚠️ EVERY ROUTE HERE CHANGES THE RADIO. Reads are safe; these are not. The C++
// project's own rule - never probe a live rig with a control route - is about
// this file.

// catRig is what the table needs from a radio: raw verbs and raw queries.
// Anything that cannot do both simply does not get these routes, rather than
// getting versions of them that quietly do nothing.
type catRig interface {
	Send(string) error
	Ask(string) (string, error)
}

// The rig's power caps, from the C++ host.
//
// ⚠️ CLAMPED, NOT REFUSED, AND THAT IS DELIBERATE HERE. Everywhere else this
// project refuses rather than clamps - but a power control that rejects 150 W by
// leaving the rig at whatever it was is worse than one that gives you 100: the
// operator asked to come DOWN and would not have.
const (
	localPowerCap = 100
	maxWatts      = 200
)

var modeCode = map[string]string{
	"LSB": "1", "USB": "2", "CW": "3", "FM": "4", "AM": "5",
	"DATA": "8", "DATA-U": "8",
}

// Band centres, from the C++ host's table.
var bandCentre = map[string]int64{
	"160": 1880000, "80": 3860000, "60": 5330500, "40": 7200000,
	"30": 10130000, "20": 14200000, "17": 18130000, "15": 21300000,
	"12": 24940000, "10": 28400000, "6": 50125000,
}

// modeForFreq is the band plan, and it rides along with every frequency change.
//
// ⚠️ CHANGING BAND WITHOUT CHANGING MODE LANDS YOU ON 40 m IN USB, which is
// legal, wrong, and sounds like a broken radio to everyone listening.
func modeForFreq(hz int64) string {
	switch {
	case hz >= 5300000 && hz <= 5500000:
		return "USB" // 60 m is USB by band plan whatever the frequency suggests
	case hz >= 10100000 && hz <= 10150000:
		return "CW" // 30 m is CW and digital only
	case hz < 10000000:
		return "LSB"
	default:
		return "USB"
	}
}

func pad3(n int) string { return fmt.Sprintf("%03d", n) }

// clampInt keeps a setting inside what the radio will accept.
func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// toggleState reads a setting back before changing it.
//
// ⚠️ READ, DON'T ASSUME. A toggle that tracks its own idea of the state is wrong
// the moment anybody touches the front panel - which on this station is the
// normal case, because the operator is sitting in front of the radio. And if the
// read does not come back in the shape expected, this REFUSES: writing a value
// derived from a reply nobody understood is how you end up transmitting on the
// wrong antenna.
func toggleState(r catRig, query string) (int, error) {
	reply, err := r.Ask(query)
	if err != nil {
		return 0, fmt.Errorf("the radio did not answer %s: %w", query, err)
	}
	reply = strings.TrimSpace(reply)
	prefix := strings.TrimSuffix(query, ";")
	if !strings.HasPrefix(reply, prefix) || !strings.HasSuffix(reply, ";") {
		return 0, fmt.Errorf("the radio answered %q to %s, which is not a reading of it", reply, query)
	}
	digits := strings.TrimSuffix(strings.TrimPrefix(reply, prefix), ";")
	if digits == "" {
		return 0, fmt.Errorf("the radio answered %q to %s with no value", reply, query)
	}
	n, err := strconv.Atoi(digits)
	if err != nil {
		return 0, fmt.Errorf("the radio answered %q to %s, which is not a number", reply, query)
	}
	return n, nil
}

// registerCAT adds every rig-control route in the table above.
func (s *Server) registerCAT(mux routeMux) {
	r, ok := s.Rig.(catRig)
	if !ok {
		// ⚠️ Say so rather than registering routes that answer 200 and do
		// nothing. A route inventory that matches while the behaviour does not
		// is a documented failure of this project's own audit.
		return
	}

	// One verb, no argument.
	simple := map[string]string{
		"/api/preamp/on":  "PA01;",
		"/api/preamp/off": "PA00;",
		"/api/comp/on":    "PR02;",
		"/api/comp/off":   "PR01;",
		"/api/mon/on":     "ML0001;",
		"/api/mon/off":    "ML0000;",
		"/api/notch/on":   "BC01;",
		"/api/notch/off":  "BC00;",
		"/api/ant/rx/on":  "EX0301031;",
		"/api/ant/rx/off": "EX0301030;",
		"/api/rit/clear":  "RC;",
		"/api/vfo/swap":   "SV;",
		"/api/cw/stop":    "KY0;",
		// ⚠️ THE RIG'S OWN ATU, NOT THE TGXL. They are different boxes and each
		// names itself in its reply, so a confirmation can never just say
		// "tuning" and leave the operator guessing which one is about to key up.
		"/api/tune": "AC002;",
	}
	for path, cat := range simple {
		s.catRoute(mux, path, func(_ string) ([]string, map[string]any, error) {
			return []string{cat}, nil, nil
		})
	}

	// Read the current value, then step it.
	cycles := []struct {
		path, query, write string
		modulo             int
	}{
		{"/api/agc/cycle", "GT0;", "GT0%d;", 4},
		{"/api/preamp/cycle", "PA0;", "PA0%d;", 3},
		{"/api/ant/toggle", "AN0;", "AN0%d;", 3},
	}
	for _, c := range cycles {
		c := c
		s.catRoute(mux, c.path, func(_ string) ([]string, map[string]any, error) {
			cur, err := toggleState(r, c.query)
			if err != nil {
				return nil, nil, err
			}
			next := (cur + 1) % c.modulo
			return []string{fmt.Sprintf(c.write, next)}, map[string]any{
				"was": cur, "now": next}, nil
		})
	}

	// Two-state toggles, each read back first.
	toggles := []struct{ path, query, off, on string }{
		{"/api/comp/toggle", "PR0;", "PR01;", "PR02;"},
		{"/api/mon/toggle", "ML0;", "ML0000;", "ML0001;"},
		{"/api/notch/toggle", "BC0;", "BC00;", "BC01;"},
		{"/api/toggle/notch", "BC0;", "BC00;", "BC01;"},
		{"/api/ant/rx/toggle", "EX030103;", "EX0301030;", "EX0301031;"},
		{"/api/split/toggle", "ST;", "ST0;", "ST1;"},
		{"/api/toggle/lock", "LK;", "LK0;", "LK1;"},
		{"/api/vfo-lock/toggle", "LK;", "LK0;", "LK1;"},
	}
	for _, t := range toggles {
		t := t
		s.catRoute(mux, t.path, func(_ string) ([]string, map[string]any, error) {
			cur, err := toggleState(r, t.query)
			if err != nil {
				return nil, nil, err
			}
			on := cur == 0 // it was off, so turn it on
			cat := t.off
			if on {
				cat = t.on
			}
			return []string{cat}, map[string]any{"now": on}, nil
		})
	}

	// ⚠️ A SEQUENCE, NOT A VERB. Quick split reads A, puts it on B, and turns
	// split on - four commands in order, and half of it is worse than none.
	s.catRoute(mux, "/api/quick-split", func(_ string) ([]string, map[string]any, error) {
		return []string{"FA;", "VS1;", "VS0;", "ST1;"}, nil, nil
	})

	// Parameterised.
	s.catPrefix(mux, "/api/mode/", func(a string) ([]string, map[string]any, error) {
		code, ok := modeCode[strings.ToUpper(a)]
		if !ok {
			return nil, nil, fmt.Errorf("unknown mode %q", a)
		}
		return []string{"MD0" + code + ";"}, map[string]any{"mode": strings.ToUpper(a)}, nil
	})
	s.catPrefix(mux, "/api/band/", func(a string) ([]string, map[string]any, error) {
		hz, ok := bandCentre[a]
		if !ok {
			return nil, nil, fmt.Errorf("unknown band %q", a)
		}
		mode := modeForFreq(hz)
		return []string{"MD0" + modeCode[mode] + ";", fmt.Sprintf("FA%09d;", hz)},
			map[string]any{"band": a, "freq": hz, "mode": mode}, nil
	})
	s.catPrefix(mux, "/api/freq/set/", func(a string) ([]string, map[string]any, error) {
		hz, err := strconv.ParseInt(a, 10, 64)
		if err != nil {
			return nil, nil, fmt.Errorf("frequency is not a number")
		}
		if hz < 1_800_000 || hz > 54_000_000 {
			return nil, nil, fmt.Errorf("%d Hz is outside 1.8-54 MHz", hz)
		}
		mode := modeForFreq(hz)
		return []string{fmt.Sprintf("FA%09d;", hz), "MD0" + modeCode[mode] + ";"},
			map[string]any{"freq": hz, "mode": mode}, nil
	})
	s.catPrefix(mux, "/api/power/set/", func(a string) ([]string, map[string]any, error) {
		w, err := strconv.Atoi(a)
		if err != nil {
			return nil, nil, fmt.Errorf("power is not a number")
		}
		asked := w
		w = clampInt(w, 0, maxWatts)
		if w > localPowerCap {
			w = localPowerCap
		}
		return []string{"PC" + pad3(w) + ";"},
			map[string]any{"power": w, "clamped": w != asked}, nil
	})
	setters := []struct {
		path, format string
		lo, hi       int
		field        string
	}{
		{"/api/volume/set/", "AG0%03d;", 0, 255, "volume"},
		{"/api/rf-gain/set/", "RG0%03d;", 0, 255, "rf_gain"},
		{"/api/cw-speed/set/", "KS%03d;", 4, 60, "cw_speed"},
		{"/api/memory/recall/", "MC%03d;", 0, 117, "memory"},
		{"/api/remote-tx/gain/", "EX010113%03d;", 0, 100, "rport_gain"},
		{"/api/ssb-out-level/set/", "EX010109%03d;", 0, 100, "ssb_out_level"},
	}
	for _, st := range setters {
		st := st
		s.catPrefix(mux, st.path, func(a string) ([]string, map[string]any, error) {
			v, err := strconv.Atoi(a)
			if err != nil {
				return nil, nil, fmt.Errorf("%s is not a number", st.field)
			}
			v = clampInt(v, st.lo, st.hi)
			return []string{fmt.Sprintf(st.format, v)}, map[string]any{st.field: v}, nil
		})
	}
	// ── Reading settings back ────────────────────────────────────────────────
	//
	// ⚠️ ASKED OF THE RADIO, EVERY TIME. The panel's poll is up to half a second
	// old and does not carry these at all; a "get" that answered from a cache
	// would be telling the operator what the radio used to be set to.
	gets := []struct{ path, query, field string }{
		{"/api/volume/get", "AG0;", "volume"},
		{"/api/rf-gain/get", "RG0;", "rf_gain"},
		{"/api/cw-speed/get", "KS;", "cw_speed"},
		{"/api/ant/get", "AN0;", "ant"},
		{"/api/ant/rx/get", "EX030103;", "rx_ant"},
		{"/api/ssb-out-level/get", "EX010109;", "ssb_out_level"},
	}
	for _, g := range gets {
		g := g
		mux.HandleFunc(g.path, func(w http.ResponseWriter, req *http.Request) {
			cors(w, req)
			if !s.authed(req) {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
			v, err := toggleState(r, g.query)
			if err != nil {
				// ⚠️ null, never a plausible number. A "get" that invents a
				// value when the read failed is how a correct setting gets
				// reported as wrong and the search goes to the wrong end.
				writeJSON(w, 200, map[string]any{"status": "ok", g.field: nil,
					"read": false, "message": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"status": "ok", g.field: v, "read": true})
		})
	}
	for _, g := range []struct{ path, query, field string }{
		{"/api/freq", "FA;", "freq"},
		{"/api/freq/get", "FA;", "freq"},
		{"/api/freq-b", "FB;", "freq_b"},
	} {
		g := g
		mux.HandleFunc(g.path, func(w http.ResponseWriter, req *http.Request) {
			cors(w, req)
			if !s.authed(req) {
				writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
				return
			}
			hz, err := readFreq(r, g.query)
			if err != nil {
				writeJSON(w, 200, map[string]any{"status": "ok", g.field: nil,
					"read": false, "message": err.Error()})
				return
			}
			writeJSON(w, 200, map[string]any{"status": "ok", g.field: hz, "read": true})
		})
	}

	// The power ceilings, so a client can draw a slider that cannot ask for more
	// than the host will send.
	for _, p := range []struct {
		path  string
		field string
		val   int
	}{
		{"/api/power/max", "max_watts", maxWatts},
		{"/api/power/limit", "limit_watts", localPowerCap},
	} {
		p := p
		mux.HandleFunc(p.path, func(w http.ResponseWriter, req *http.Request) {
			cors(w, req)
			writeJSON(w, 200, map[string]any{"status": "ok", p.field: p.val})
		})
	}

	// ── Nudges: read, step, write ────────────────────────────────────────────
	nudges := []struct {
		path, query, format string
		delta, lo, hi       int
	}{
		{"/api/volume/up", "AG0;", "AG0%03d;", 5, 0, 255},
		{"/api/volume/down", "AG0;", "AG0%03d;", -5, 0, 255},
		{"/api/cw-speed/up", "KS;", "KS%03d;", 1, 4, 60},
		{"/api/cw-speed/down", "KS;", "KS%03d;", -1, 4, 60},
	}
	for _, n := range nudges {
		n := n
		s.catRoute(mux, n.path, func(_ string) ([]string, map[string]any, error) {
			cur, err := toggleState(r, n.query)
			if err != nil {
				// ⚠️ REFUSED, not assumed. A nudge is relative: without the
				// current value there is nothing to step from, and guessing zero
				// would slam the volume to 5 from wherever it actually was.
				return nil, nil, err
			}
			next := clampInt(cur+n.delta, n.lo, n.hi)
			return []string{fmt.Sprintf(n.format, next)},
				map[string]any{"was": cur, "now": next}, nil
		})
	}

	// VFO, split and lock.
	for path, cat := range map[string]string{
		"/api/vfo/a":     "VS0;",
		"/api/vfo/b":     "VS1;",
		"/api/lock/on":   "LK1;",
		"/api/lock/off":  "LK0;",
		"/api/split/on":  "ST1;",
		"/api/split/off": "ST0;",
	} {
		cat := cat
		s.catRoute(mux, path, func(_ string) ([]string, map[string]any, error) {
			return []string{cat}, nil, nil
		})
	}

	// ⚠️ SH00<nn>, and the index is NOT the width in Hz. The C++ host carries
	// both so the reply can tell the operator the bandwidth they actually got
	// rather than the filter number, which means nothing at the microphone.
	for _, wsp := range []struct {
		name string
		idx  int
		hz   int
	}{{"narrow", 6, 1800}, {"medium", 10, 2400}, {"wide", 14, 3000}} {
		wsp := wsp
		s.catRoute(mux, "/api/width/"+wsp.name, func(_ string) ([]string, map[string]any, error) {
			return []string{fmt.Sprintf("SH00%02d;", wsp.idx)},
				map[string]any{"width": wsp.name, "hz": wsp.hz}, nil
		})
	}

	// ⚠️ RU/RD CARRY A FOUR-DIGIT OFFSET - a bare "RU;" is not a command, it is a
	// query, and sending it where a nudge was meant moves nothing while looking
	// like it worked. The offset is read first and the verb picked by sign.
	for _, n := range []struct {
		path  string
		delta int
	}{{"/api/rit/up", 100}, {"/api/rit/down", -100}} {
		n := n
		s.catRoute(mux, n.path, func(_ string) ([]string, map[string]any, error) {
			cur, err := toggleState(r, "RT;") // current RIT offset
			if err != nil {
				cur = 0 // an unreadable offset is treated as zero, not refused:
				// the nudge is relative and the radio is about to be told an
				// absolute value either way.
			}
			next := cur + n.delta
			cat := fmt.Sprintf("RU%04d;", next)
			if next < 0 {
				cat = fmt.Sprintf("RD%04d;", -next)
			}
			return []string{cat}, map[string]any{"rit": next}, nil
		})
	}

	// ⚠️ READ-MODIFY-WRITE. Stepping and copying need the CURRENT frequency, so
	// they read it back from the radio rather than from the panel's last poll -
	// which can be half a second old, and half a second is several clicks of a
	// tuning knob.
	s.catPrefix(mux, "/api/step/", func(a string) ([]string, map[string]any, error) {
		parts := strings.Split(a, "/")
		if len(parts) != 2 {
			return nil, nil, fmt.Errorf("expected <hz>/<up|down>")
		}
		hz, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			return nil, nil, fmt.Errorf("step is not a number")
		}
		if parts[1] != "up" && parts[1] != "down" {
			return nil, nil, fmt.Errorf("direction must be up or down")
		}
		if parts[1] == "down" {
			hz = -hz
		}
		cur, err := readFreq(r, "FA;")
		if err != nil {
			return nil, nil, err
		}
		next := cur + hz
		if next < 1_800_000 || next > 54_000_000 {
			return nil, nil, fmt.Errorf("stepping there would leave 1.8-54 MHz")
		}
		return []string{fmt.Sprintf("FA%09d;", next)},
			map[string]any{"freq": next, "from": cur}, nil
	})
	for _, c := range []struct{ path, from, to string }{
		{"/api/vfo-copy/a2b", "FA;", "FB"},
		{"/api/vfo-copy/b2a", "FB;", "FA"},
	} {
		c := c
		s.catRoute(mux, c.path, func(_ string) ([]string, map[string]any, error) {
			f, err := readFreq(r, c.from)
			if err != nil {
				return nil, nil, err
			}
			return []string{fmt.Sprintf("%s%09d;", c.to, f)},
				map[string]any{"freq": f}, nil
		})
	}
}

// readFreq asks the radio where it is and refuses to guess.
//
// ⚠️ NINE DIGITS AT OFFSET 2. The reply offsets in this protocol are NOT
// uniform - the S-meter is three digits at offset 3 and reading it as four
// returned a plausible zero for a live band. A short or malformed reply here is
// an error, never a frequency.
func readFreq(r catRig, query string) (int64, error) {
	reply, err := r.Ask(query)
	if err != nil {
		return 0, fmt.Errorf("the radio did not answer %s: %w", query, err)
	}
	reply = strings.TrimSpace(reply)
	prefix := strings.TrimSuffix(query, ";")
	if len(reply) < len(prefix)+10 || !strings.HasPrefix(reply, prefix) {
		return 0, fmt.Errorf("the radio answered %q to %s, which is not a frequency", reply, query)
	}
	hz, err := strconv.ParseInt(reply[len(prefix):len(prefix)+9], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("the radio answered %q to %s, which is not a number", reply, query)
	}
	return hz, nil
}

type catBuilder func(arg string) ([]string, map[string]any, error)

func (s *Server) catRoute(mux routeMux, path string, build catBuilder) {
	mux.HandleFunc(path, s.catHandler("", build))
}

func (s *Server) catPrefix(mux routeMux, prefix string, build catBuilder) {
	mux.HandleFunc(prefix, s.catHandler(prefix, build))
}

func (s *Server) catHandler(prefix string, build catBuilder) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cors(w, r)
		if !s.authed(r) {
			writeJSON(w, 401, map[string]string{"status": "error", "message": "login required"})
			return
		}
		rig, ok := s.Rig.(catRig)
		if !ok {
			writeJSON(w, 503, map[string]string{"status": "error",
				"message": "this host's radio does not accept raw commands"})
			return
		}
		arg := ""
		if prefix != "" {
			arg = strings.TrimPrefix(r.URL.Path, prefix)
		}
		cmds, extra, err := build(arg)
		if err != nil {
			writeJSON(w, 400, map[string]string{"status": "error", "message": err.Error()})
			return
		}
		for i, c := range cmds {
			if err := rig.Send(c); err != nil {
				// ⚠️ Name WHICH command failed and how far the sequence got.
				// Quick split is four verbs; "it failed" tells the operator
				// nothing about whether the radio is now half-configured.
				writeJSON(w, 502, map[string]any{"status": "error",
					"message": fmt.Sprintf("the radio refused %s (command %d of %d): %v",
						c, i+1, len(cmds), err),
					"sent": cmds[:i]})
				return
			}
		}
		out := map[string]any{"status": "ok", "sent": cmds}
		for k, v := range extra {
			out[k] = v
		}
		writeJSON(w, 200, out)
	}
}
