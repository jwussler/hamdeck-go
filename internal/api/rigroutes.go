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
func (s *Server) registerCAT(mux *http.ServeMux) {
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
}

type catBuilder func(arg string) ([]string, map[string]any, error)

func (s *Server) catRoute(mux *http.ServeMux, path string, build catBuilder) {
	mux.HandleFunc(path, s.catHandler("", build))
}

func (s *Server) catPrefix(mux *http.ServeMux, prefix string, build catBuilder) {
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
