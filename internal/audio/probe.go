// Package audio: reading the radio's receiver, and feeding its transmitter.
//
// ⚠️ PURE GO, NO cgo. github.com/yobert/alsa talks to /dev/snd directly rather
// than linking libasound, which keeps the whole server a `go build` and keeps
// cross-compiling for a Pi honest. If this turns out not to work on the real
// codec, that is a finding worth having early rather than after a streaming path
// has been written on top of it.
package audio

import (
	"fmt"
	"strings"
	"time"

	"github.com/yobert/alsa"
)

// Device lists what the machine actually has, by name.
//
// ⚠️ BY NAME, NEVER BY INDEX. Indices shift when USB devices come and go, and an
// index that moved is how a host ends up recording from the wrong thing while
// every counter looks healthy - the C++ client has a scar exactly here.
func List() ([]string, error) {
	cards, err := alsa.OpenCards()
	if err != nil {
		return nil, err
	}
	defer alsa.CloseCards(cards)

	var out []string
	for _, card := range cards {
		devs, err := card.Devices()
		if err != nil {
			continue
		}
		for _, d := range devs {
			dir := "playback"
			if d.Type == alsa.PCM && d.Play == false {
				dir = "capture"
			}
			out = append(out, fmt.Sprintf("%s | %s | %s | play=%v record=%v",
				card.Title, d.Title, dir, d.Play, d.Record))
		}
	}
	return out, nil
}

// Probe opens the first capture device whose card title contains `match`, reads
// for `dur`, and reports the PEAK it saw.
//
// ⚠️ THE PEAK IS THE WHOLE POINT. "Frames were read" is not evidence of audio:
// a muted input, a dead cable and a radio with its AF turned down all produce
// perfectly formed silence at exactly the right rate. This project has now been
// bitten by that on transmit AND on receive, so the very first thing the Go host
// learns to do is tell audio from nothing.
func Probe(match string, dur time.Duration) (string, int, error) {
	cards, err := alsa.OpenCards()
	if err != nil {
		return "", 0, err
	}
	defer alsa.CloseCards(cards)

	for _, card := range cards {
		if match != "" && !strings.Contains(strings.ToLower(card.Title), strings.ToLower(match)) {
			continue
		}
		devs, err := card.Devices()
		if err != nil {
			continue
		}
		for _, d := range devs {
			if !d.Record {
				continue
			}
			if err := d.Open(); err != nil {
				return "", 0, fmt.Errorf("%s: %w", d.Title, err)
			}
			defer d.Close()

			ch, err := d.NegotiateChannels(1, 2)
			if err != nil {
				return "", 0, fmt.Errorf("channels: %w", err)
			}
			rate, err := d.NegotiateRate(22050, 44100, 48000)
			if err != nil {
				return "", 0, fmt.Errorf("rate: %w", err)
			}
			format, err := d.NegotiateFormat(alsa.S16_LE)
			if err != nil {
				return "", 0, fmt.Errorf("format: %w", err)
			}
			// ⚠️ BUFFER SIZE, NOT PERIOD SIZE, AND THE ORDER MATTERS. Negotiating
			// a period and then reading gave EIO on the very first read against
			// the real codec: the library's Prepare() derives its software
			// start/stop thresholds from the BUFFER size, so a stream set up by
			// period alone is prepared with thresholds it never reaches and the
			// first read fails. The library's own recorder negotiates the buffer;
			// this now does the same.
			bufFrames, err := d.NegotiateBufferSize(8192, 16384)
			if err != nil {
				return "", 0, fmt.Errorf("buffer size: %w", err)
			}
			if err := d.Prepare(); err != nil {
				return "", 0, fmt.Errorf("prepare: %w", err)
			}

			desc := fmt.Sprintf("%s / %s @ %d Hz, %d ch, %v, %d frame buffer",
				card.Title, d.Title, rate, ch, format, bufFrames)

			// ⚠️ ONE WHOLE BUFFER PER READ. Prepare() sets the stream's start
			// threshold to the buffer size, so a read of fewer frames than that
			// waits for a start that never comes and returns EIO on the first
			// call - which reads as "the device is broken" and is really "you
			// asked for less than it was set up to deliver".
			raw := make([]byte, bufFrames*d.BytesPerFrame())
			peak := 0
			deadline := time.Now().Add(dur)
			for time.Now().Before(deadline) {
				if err := d.Read(raw); err != nil {
					return desc, peak, fmt.Errorf("read: %w", err)
				}
				// ⚠️ Little-endian by hand rather than a cast: the wire format is
				// S16_LE and assuming the host's byte order happens to match is
				// how a big-endian build reads noise as signal.
				for i := 0; i+1 < len(raw); i += 2 {
					v := int(int16(uint16(raw[i]) | uint16(raw[i+1])<<8))
					if v < 0 {
						v = -v
					}
					if v > peak {
						peak = v
					}
				}
			}
			return desc, peak, nil
		}
	}
	return "", 0, fmt.Errorf("no capture device matching %q", match)
}
