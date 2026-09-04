package sculan

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"
)

// ⚠️ THE PUBLISHED TABLE IS THE GROUND TRUTH, and this is the whole reason the
// codec can be trusted before any hardware exists. The spec prints its first 256
// gTable values; if the formula in this package reproduces them byte for byte,
// the scramble is right. If it does not, everything downstream - audio, CAT,
// spectrum - would decode into plausible-looking nonsense with no error anywhere.
const publishedGTable = `
06 05 04 0B 0A 09 08 0F 0E 0D 0C 13 12 11 10 17
16 15 14 1B 1A 19 18 1F 1E 1D 1C 23 22 21 20 27
26 25 24 2B 2A 29 28 2F 2E 2D 2C 33 32 31 30 37
36 35 34 3B 3A 39 38 3F 3E 3D 3C 43 42 41 40 47
46 45 44 4B 4A 49 48 4F 4E 4D 4C 53 52 51 50 57
56 55 54 5B 5A 59 58 5F 5E 5D 5C 63 62 61 60 67
66 65 64 6B 6A 69 68 6F 6E 6D 6C 73 72 71 70 77
76 75 74 7B 7A 79 78 7F 7E 7D 7C 83 82 81 80 87
86 85 84 8B 8A 89 88 8F 8E 8D 8C 93 92 91 90 97
96 95 94 9B 9A 99 98 9F 9E 9D 9C A3 A2 A1 A0 A7
A6 A5 A4 AB AA A9 A8 AF AE AD AC B3 B2 B1 B0 B7
B6 B5 B4 BB BA B9 B8 BF BE BD BC C3 C2 C1 C0 C7
C6 C5 C4 CB CA C9 C8 CF CE CD CC D3 D2 D1 D0 D7
D6 D5 D4 DB DA D9 D8 DF DE DD DC E3 E2 E1 E0 E7
E6 E5 E4 EB EA E9 E8 EF EE ED EC F3 F2 F1 F0 F7
F6 F5 F4 FB FA F9 F8 FF FE FD FC 03 02 01 00 07`

func TestGTableMatchesTheSpec(t *testing.T) {
	want, err := hex.DecodeString(strings.Join(strings.Fields(publishedGTable), ""))
	if err != nil {
		t.Fatalf("the published table in this test is not valid hex: %v", err)
	}
	if len(want) != 256 {
		t.Fatalf("expected 256 published values, parsed %d", len(want))
	}
	for i, w := range want {
		if gTable[i] != w {
			t.Fatalf("gTable[%d] = %#02x, the spec says %#02x - the formula is wrong",
				i, gTable[i], w)
		}
	}
}

// The table is periodic with period 256; a longer table must keep repeating it,
// or long bodies (a 4096-byte scope packet) decode correctly for the first 256
// bytes and turn to noise after - which looks like a signal, not a bug.
func TestGTableRepeatsBeyond256(t *testing.T) {
	for i := 256; i < len(gTable); i++ {
		if gTable[i] != gTable[i%256] {
			t.Fatalf("gTable[%d] = %#02x but gTable[%d] = %#02x", i, gTable[i], i%256, gTable[i%256])
		}
	}
}

func TestHeaderRoundTrip(t *testing.T) {
	for _, h := range []Header{
		{Seq: 0x06, Channel: ChanCTRL, MsgType: 0x03, Key: 0x3A, BodyLen: 68},
		{Seq: 0xFF, Channel: ChanSCOPE, MsgType: 0x01, Key: 0x00, BodyLen: 4096},
		{Seq: 0x00, Channel: ChanAUDIO, MsgType: 0x06, Key: 0xFF, BodyLen: 668},
	} {
		b := h.Encode()
		got, err := DecodeHeader(b[:])
		if err != nil {
			t.Fatalf("%+v did not survive its own encoding: %v", h, err)
		}
		if got != h {
			t.Fatalf("round trip changed the header:\n got %+v\nwant %+v", got, h)
		}
	}
}

// ⚠️ A 4096-byte scope body is the case that matters: it is the longest, and it
// is the one whose failure looks like a picture rather than like an error.
func TestBodyRoundTripAtScopeLength(t *testing.T) {
	body := make([]byte, 4096)
	for i := range body {
		body[i] = byte(i * 7 % 251)
	}
	original := append([]byte(nil), body...)

	pkt := Frame(Header{Seq: 9, Channel: ChanSCOPE, MsgType: 0x01, Key: 0xA5}, body)
	if !bytes.Equal(body, original) {
		t.Fatal("Frame modified the caller's slice")
	}
	h, got, err := Parse(pkt)
	if err != nil {
		t.Fatalf("parsing our own packet failed: %v", err)
	}
	if h.Channel != ChanSCOPE || h.BodyLen != 4096 {
		t.Fatalf("header came back wrong: %+v", h)
	}
	if !bytes.Equal(got, original) {
		t.Fatal("the body did not survive encrypt/decrypt")
	}
}

// The server drops inconsistent headers silently. So must we - decoding one into
// a plausible packet is how a corrupt capture becomes a day of chasing a fault
// that is not there.
func TestCorruptHeaderIsRefused(t *testing.T) {
	pkt := Frame(Header{Seq: 1, Channel: ChanCAT, MsgType: 0x01, Key: 0x5C}, []byte("FA;"))
	for _, bad := range []struct {
		name  string
		index int
	}{
		{"verify byte", 6 + 1},
		{"constant byte", 6 + 3},
		{"length low", 6 + 6},
	} {
		broken := append([]byte(nil), pkt...)
		broken[bad.index] ^= 0xFF
		if _, _, err := Parse(broken); err == nil {
			t.Fatalf("a packet with a corrupted %s was accepted", bad.name)
		}
	}
}

func TestRejectsForeignTraffic(t *testing.T) {
	if _, _, err := Parse([]byte("GET / HTTP/1.1\r\n\r\n")); err == nil {
		t.Fatal("an HTTP request was accepted as an SCU-LAN10 packet")
	}
}

// The auth body is a fixed shape, and getting it wrong produces NO error from
// the server - it simply never answers. Worth a test precisely because the
// failure mode is silence.
func TestAuthBodyShape(t *testing.T) {
	body := AuthBody("defaultuser", "defaultuser")
	if len(body) != 68 {
		t.Fatalf("auth body is %d bytes, the spec says 68", len(body))
	}
	if body[0] != 0x01 || body[1] != 0x00 {
		t.Fatalf("auth body does not start 01 00: % x", body[:2])
	}
	if string(bytes.TrimRight(body[2:35], "\x00")) != "defaultuser" {
		t.Fatal("username is not where the spec puts it")
	}
	if string(bytes.TrimRight(body[35:68], "\x00")) != "defaultuser" {
		t.Fatal("password is not where the spec puts it")
	}
	// ⚠️ Over-long credentials must be REFUSED, not truncated. A silently
	// shortened password fails auth with no error packet at all.
	if AuthBody(strings.Repeat("x", 33), "p") != nil {
		t.Fatal("a 33-character username was accepted; the field holds 32")
	}
}
