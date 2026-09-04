// Package sculan speaks the Yaesu SCU-LAN10 wire protocol.
//
// ⚠️ THIS IS SOMEBODY ELSE'S WORK, WRITTEN DOWN INDEPENDENTLY. The format comes
// from CarrierWaveApp/sculan10-protocol (MIT), reverse-engineered from ~76,000
// captured packets and confirmed against a live FTDX10. Nothing here was derived
// from Yaesu firmware or software. Where their spec flags something as
// unconfirmed, this code says so too rather than quietly picking one reading.
//
// ⚠️ THE "ENCRYPTION" IS OBFUSCATION, NOT SECURITY. There is no authentication,
// no replay protection and no key exchange - the key travels in the header of
// the packet it encrypts. Anyone on the path can read or forge traffic. It must
// never be exposed to the internet without a tunnel around it.
//
// Why this exists here: the SCU-LAN10 carries the radio's SPECTRUM SCOPE, which
// CAT does not. A waterfall built on this is measured data. A waterfall built on
// anything CAT offers would be invented, which this project refuses.
package sculan

import (
	"encoding/binary"
	"fmt"
)

// Channel ids, from the spec's header table.
const (
	ChanCTRL  byte = 0xFC
	ChanCAT   byte = 0xFD
	ChanAUDIO byte = 0xFE
	ChanSCOPE byte = 0xFA
)

// Magic is the two-byte sentinel every datagram starts with ("ZZ").
var Magic = [2]byte{0x5A, 0x5A}

// gTable is the position-dependent scramble table.
//
// ⚠️ DERIVED FROM THE FORMULA, NOT PASTED FROM THE DOCUMENT, and then checked
// against the document's own 256 published values in the tests. A table typed in
// by hand is a table with a typo in it somewhere around byte 200, and the fault
// would look like corrupted audio rather than like a typo.
var gTable [8192]byte

func init() {
	offsets := [4]int{0, 0xFF, 0xFE, 5}
	for i := range gTable {
		gTable[i] = byte((4*(i/4) + 6 + offsets[i%4]) & 0xFF)
	}
}

// Header is the 8 bytes between the framing and the encrypted body.
type Header struct {
	Seq     byte
	Channel byte
	MsgType byte
	Key     byte
	BodyLen int
}

// Encode writes the header in wire form.
//
// ⚠️ EVERY BYTE EXCEPT THE SEQUENCE IS XOR'D WITH THE KEY, including the length.
// The server cross-checks b1, b3, b6 and b7 against the implied key and silently
// DROPS anything inconsistent - no error, no reply. A client that gets one of
// these wrong looks exactly like a client with a network problem.
func (h Header) Encode() [8]byte {
	k := h.Key
	return [8]byte{
		h.Seq,
		k ^ h.Seq ^ 0xFC,
		k ^ h.Channel,
		k ^ 0x03,
		k ^ h.MsgType,
		k,
		k ^ byte(h.BodyLen&0xFF),
		k ^ (0x07 ^ byte(h.BodyLen>>8)),
	}
}

// DecodeHeader reads a header and REFUSES one that does not check out.
func DecodeHeader(b []byte) (Header, error) {
	if len(b) < 8 {
		return Header{}, fmt.Errorf("header is %d bytes, needs 8", len(b))
	}
	k := b[5]
	h := Header{
		Seq:     b[0],
		Channel: b[2] ^ k,
		MsgType: b[4] ^ k,
		Key:     k,
		BodyLen: int(b[6]^k) | int((b[7]^k)^0x07)<<8,
	}
	// The same four checks the server makes. ⚠️ Doing them here too means a
	// corrupted capture is rejected as corrupt rather than decoded into
	// plausible nonsense - which is the failure that wastes a day.
	if b[1] != k^h.Seq^0xFC {
		return Header{}, fmt.Errorf("verify byte is %#02x, expected %#02x", b[1], k^h.Seq^0xFC)
	}
	if b[3] != k^0x03 {
		return Header{}, fmt.Errorf("constant byte is %#02x, expected %#02x", b[3], k^0x03)
	}
	return h, nil
}

// Crypt applies the XOR in place. It is its own inverse.
func Crypt(body []byte, key byte) {
	for i := range body {
		body[i] ^= key ^ gTable[i]
	}
}

// Frame builds a complete datagram: magic, length, type, header, encrypted body.
func Frame(h Header, body []byte) []byte {
	h.BodyLen = len(body)
	enc := make([]byte, len(body))
	copy(enc, body)
	Crypt(enc, h.Key)

	out := make([]byte, 0, len(body)+12)
	out = append(out, Magic[0], Magic[1])
	// ⚠️ The length counts the type word, the header and the body: body+10.
	out = binary.LittleEndian.AppendUint16(out, uint16(len(body)+10))
	out = append(out, 0x00, 0x01)
	hb := h.Encode()
	out = append(out, hb[:]...)
	return append(out, enc...)
}

// Parse takes one datagram apart and returns the header and DECRYPTED body.
func Parse(pkt []byte) (Header, []byte, error) {
	if len(pkt) < 14 {
		return Header{}, nil, fmt.Errorf("packet is %d bytes, too short to be framed", len(pkt))
	}
	if pkt[0] != Magic[0] || pkt[1] != Magic[1] {
		return Header{}, nil, fmt.Errorf("no 5A 5A magic - not an SCU-LAN10 packet")
	}
	declared := int(binary.LittleEndian.Uint16(pkt[2:4]))
	h, err := DecodeHeader(pkt[6:14])
	if err != nil {
		return Header{}, nil, err
	}
	body := pkt[14:]
	// ⚠️ Three lengths that must agree: the framing, the header, and what
	// actually arrived. Trusting any one of them alone is how a truncated
	// datagram becomes a spectrum line with garbage on the end.
	if declared != len(body)+10 {
		return h, nil, fmt.Errorf("length field says %d, body is %d bytes", declared, len(body))
	}
	if h.BodyLen != len(body) {
		return h, nil, fmt.Errorf("header says %d body bytes, got %d", h.BodyLen, len(body))
	}
	out := make([]byte, len(body))
	copy(out, body)
	Crypt(out, h.Key)
	return h, out, nil
}

// AuthBody builds the 68-byte authentication payload.
//
// ⚠️ THE FACTORY DEFAULT IS user "defaultuser", password "defaultuser". If those
// still work on a box, so does anyone else on the network - and bad credentials
// produce NO response at all, so a wrong password and an unplugged box look
// identical from here.
//
// Returns nil if either field is too long. ⚠️ Refused, never truncated: a
// silently shortened password fails authentication with silence, which is the
// hardest possible thing to diagnose.
func AuthBody(user, password string) []byte {
	if len(user) > 32 || len(password) > 32 {
		return nil
	}
	b := make([]byte, 68)
	b[0], b[1] = 0x01, 0x00
	copy(b[2:35], user)
	copy(b[35:68], password)
	return b
}
