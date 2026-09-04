// scudecode reads a pcap of SCU-LAN10 traffic and takes it apart.
//
// ⚠️ THE POINT IS TO MAKE A CAPTURE SESSION PRODUCTIVE WHILE THE RADIO IS STILL
// PLUGGED IN. Capturing 76,000 packets and then discovering at the desk that the
// scope was switched off, or that authentication never completed, means doing
// the whole thing again with the station torn down twice.
//
// So it reports, per channel: how many packets decoded cleanly, how many were
// refused and why, and - for the scope - whether the spectrum actually looks
// like spectrum.
//
// Usage: scudecode capture.pcap [-scope-dump lines.csv]
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"sort"

	"github.com/jwussler/hamdeck-go/internal/sculan"
)

type stats struct {
	ok, bad int
	reasons map[string]int
	bodies  []int
}

func main() {
	scopeDump := flag.String("scope-dump", "", "write decoded spectrum lines to this CSV")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: scudecode <capture.pcap> [-scope-dump lines.csv]")
		os.Exit(2)
	}
	pkts, err := readPcapUDP(flag.Arg(0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
	fmt.Printf("%d UDP payloads in the capture\n\n", len(pkts))

	byChan := map[byte]*stats{}
	var scopeLines [][]byte
	for _, p := range pkts {
		h, body, err := sculan.Parse(p)
		ch := h.Channel
		s := byChan[ch]
		if s == nil {
			s = &stats{reasons: map[string]int{}}
			byChan[ch] = s
		}
		if err != nil {
			s.bad++
			s.reasons[err.Error()]++
			continue
		}
		s.ok++
		s.bodies = append(s.bodies, len(body))
		if ch == sculan.ChanSCOPE && len(body) == 4096 {
			scopeLines = append(scopeLines, body)
		}
	}

	names := map[byte]string{
		sculan.ChanCTRL: "CTRL", sculan.ChanCAT: "CAT",
		sculan.ChanAUDIO: "AUDIO", sculan.ChanSCOPE: "SCOPE",
	}
	chans := make([]int, 0, len(byChan))
	for c := range byChan {
		chans = append(chans, int(c))
	}
	sort.Ints(chans)
	for _, ci := range chans {
		c := byte(ci)
		s := byChan[c]
		name := names[c]
		if name == "" {
			// ⚠️ An unknown channel id is REPORTED, not dropped. On an FTDX101 -
			// which nobody has captured - a second receiver could plausibly
			// appear as a channel the spec has never seen, and that is exactly
			// the finding worth having.
			name = fmt.Sprintf("UNKNOWN(%#02x)", c)
		}
		fmt.Printf("%-14s %5d decoded, %4d refused\n", name, s.ok, s.bad)
		for r, n := range s.reasons {
			fmt.Printf("               %4d x %s\n", n, r)
		}
		if len(s.bodies) > 0 {
			fmt.Printf("               body sizes: %s\n", sizeSummary(s.bodies))
		}
	}

	if len(scopeLines) > 0 {
		fmt.Printf("\n== SCOPE ==\n")
		analyseScope(scopeLines)
		if *scopeDump != "" {
			if err := dumpScope(*scopeDump, scopeLines); err != nil {
				fmt.Fprintln(os.Stderr, "could not write the dump:", err)
			} else {
				fmt.Printf("wrote %d spectrum lines to %s\n", len(scopeLines), *scopeDump)
			}
		}
	}
}

// analyseScope answers the question the capture exists to answer.
//
// ⚠️ IT CHECKS WHETHER THE SPECTRUM LOOKS LIKE SPECTRUM, not whether packets
// arrived. A stream of 4096-byte packets that decode without error and contain a
// flat value is a scope that was switched off - and it counts, meters and
// decodes exactly like a working one.
func analyseScope(lines [][]byte) {
	l := lines[len(lines)/2] // the middle of the capture, not the first frame

	marker := -1
	for i := 500; i < 3000 && i < len(l); i++ {
		if l[i] <= 1 {
			marker = i
			break
		}
	}
	if marker < 0 {
		fmt.Println("  no boundary marker found between bins 500 and 3000 -")
		fmt.Println("  either the span is unusual or this is not spectrum data")
	} else {
		fmt.Printf("  boundary marker at byte %d  ->  %d usable bins (marker/2)\n",
			marker, marker/2)
	}

	// The noise floor should sit high (values are INVERTED - 255 is weakest).
	n := marker
	if n <= 0 {
		n = 1700
	}
	var min, max, sum int
	min = 255
	for _, v := range l[:n] {
		if int(v) < min {
			min = int(v)
		}
		if int(v) > max {
			max = int(v)
		}
		sum += int(v)
	}
	mean := sum / n
	fmt.Printf("  active region: min %d (strongest), mean %d, max %d (weakest)\n", min, mean, max)
	if max-min < 20 {
		fmt.Println("  ⚠ FLAT. That is a scope that is switched off, not a quiet band -")
		fmt.Println("    turn the spectrum scope on in FT-Control and capture again.")
	} else {
		fmt.Println("  looks like real spectrum: there is a noise floor and there are signals")
	}

	// ⚠️ THE FTDX101 QUESTION. The published spec has only ever seen an FTDX10,
	// and the other repo says bytes 850-1699 are reserved for the 101's SECOND
	// receiver. If this radio fills that region with something other than the
	// reference block, that is the new finding.
	if marker > 1699 {
		var s2 int
		for _, v := range l[850:1700] {
			s2 += int(v)
		}
		m2 := s2 / 850
		fmt.Printf("  bytes 850-1699 (reserved for the 101's second receiver): mean %d\n", m2)
		switch {
		case m2 > 225:
			fmt.Println("    flat and high - a reference block, same as the FTDX10")
		case m2 > 100 && m2 < 160:
			fmt.Println("    ⚠ CENTRED NEAR 128 - the undecoded region the spec asks about")
		default:
			fmt.Println("    ⚠ NEITHER a reference block nor centred on 128 - this may be")
			fmt.Println("      the FTDX101's second receiver. Worth reporting upstream.")
		}
	}
}

func dumpScope(path string, lines [][]byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, l := range lines {
		for i, v := range l {
			if i > 0 {
				fmt.Fprint(f, ",")
			}
			fmt.Fprint(f, v)
		}
		fmt.Fprintln(f)
	}
	return nil
}

func sizeSummary(v []int) string {
	counts := map[int]int{}
	for _, x := range v {
		counts[x]++
	}
	type kv struct{ size, n int }
	all := make([]kv, 0, len(counts))
	for s, n := range counts {
		all = append(all, kv{s, n})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].n > all[j].n })
	out := ""
	for i, e := range all {
		if i == 4 {
			out += fmt.Sprintf(", +%d more", len(all)-4)
			break
		}
		if i > 0 {
			out += ", "
		}
		out += fmt.Sprintf("%dB x%d", e.size, e.n)
	}
	return out
}

// readPcapUDP pulls UDP payloads out of a classic pcap file.
//
// ⚠️ NO CAPTURE LIBRARY ON PURPOSE. This has to run wherever the capture lands,
// including a box with no libpcap, and the classic pcap format is a 24-byte
// global header and a 16-byte record header. Nanosecond and byte-swapped
// variants are both handled, because tcpdump on one machine and Wireshark on
// another do not always agree.
func readPcapUDP(path string) ([][]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(raw) < 24 {
		return nil, fmt.Errorf("%s is too small to be a pcap", path)
	}
	var bo binary.ByteOrder = binary.LittleEndian
	switch binary.LittleEndian.Uint32(raw[:4]) {
	case 0xA1B2C3D4, 0xA1B23C4D:
	case 0xD4C3B2A1, 0x4D3CB2A1:
		bo = binary.BigEndian
	default:
		return nil, fmt.Errorf("%s is not a classic pcap (try: tcpdump -w file.pcap)", path)
	}
	link := bo.Uint32(raw[20:24])
	var l2 int
	switch link {
	case 1:
		l2 = 14 // Ethernet
	case 113:
		l2 = 16 // Linux cooked
	case 0:
		l2 = 4 // loopback
	default:
		return nil, fmt.Errorf("link type %d is not handled", link)
	}

	var out [][]byte
	for off := 24; off+16 <= len(raw); {
		caplen := int(bo.Uint32(raw[off+8 : off+12]))
		off += 16
		if off+caplen > len(raw) {
			break
		}
		pkt := raw[off : off+caplen]
		off += caplen
		if len(pkt) < l2+20 {
			continue
		}
		ip := pkt[l2:]
		if ip[0]>>4 != 4 || ip[9] != 17 { // IPv4, UDP
			continue
		}
		ihl := int(ip[0]&0x0F) * 4
		if len(ip) < ihl+8 {
			continue
		}
		payload := ip[ihl+8:]
		if len(payload) > 0 {
			out = append(out, payload)
		}
	}
	return out, nil
}
