package audio

import (
	"encoding/binary"
	"fmt"
	"os"
	"sync"
)

// TxRecorder writes the audio a client transmits to a WAV file.
//
// ⚠️ THIS IS A TEST INSTRUMENT, NOT A FEATURE. It exists so the transmit path
// can be proved without a radio and without a sound card: a client sends audio,
// this writes what actually arrived, and tools/measure_pitch.py measures it.
//
// The failure it is aimed at: the host asks for one rate on transmit and a
// different one on receive - this station's codec negotiated 22050 in and 44100
// out - and a client that reuses the receive rate for transmit sends a voice at
// half speed. It transmits, it meters, the frame counts are perfect, and it is
// unintelligible to everyone except the operator. Only measuring the pitch of
// what arrived can tell that apart from a working client.
type TxRecorder struct {
	mu       sync.Mutex
	f        *os.File
	bytes    int
	rate     int
	channels int
	peak     int
}

func NewTxRecorder(path string, rate, channels int) (*TxRecorder, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	r := &TxRecorder{f: f, rate: rate, channels: channels}
	// A placeholder header; the sizes are only known at Close.
	if _, err := f.Write(make([]byte, 44)); err != nil {
		f.Close()
		return nil, err
	}
	return r, nil
}

func (r *TxRecorder) Rate() int     { return r.rate }
func (r *TxRecorder) Channels() int { return r.channels }

func (r *TxRecorder) Describe() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return fmt.Sprintf("recording transmit audio to %s @ %d Hz %dch S16_LE",
		r.f.Name(), r.rate, r.channels)
}

// Peak is the level of what arrived, 0-32767. It does NOT decay: this is a
// recording of a finite test, and the question is whether anything ever came.
func (r *TxRecorder) Peak() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.peak
}

func (r *TxRecorder) Write(pcm []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return
	}
	for i := 0; i+1 < len(pcm); i += 2 {
		v := int(int16(uint16(pcm[i]) | uint16(pcm[i+1])<<8))
		if v < 0 {
			v = -v
		}
		if v > r.peak {
			r.peak = v
		}
	}
	n, _ := r.f.Write(pcm)
	r.bytes += n
	// ⚠️ Fix the header on EVERY write, not just at Close. The host is normally
	// stopped with a signal, and a WAV left with a zero-length header opens as an
	// empty file everywhere - indistinguishable from "the client sent nothing",
	// which is the exact thing this file exists to answer. 44 bytes per 40 ms
	// chunk costs nothing next to being unable to trust the result.
	r.writeHeader()
}

func (r *TxRecorder) writeHeader() {
	h := make([]byte, 44)
	byteRate := r.rate * r.channels * 2
	copy(h[0:], "RIFF")
	binary.LittleEndian.PutUint32(h[4:], uint32(36+r.bytes))
	copy(h[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(h[16:], 16)
	binary.LittleEndian.PutUint16(h[20:], 1) // PCM
	binary.LittleEndian.PutUint16(h[22:], uint16(r.channels))
	binary.LittleEndian.PutUint32(h[24:], uint32(r.rate))
	binary.LittleEndian.PutUint32(h[28:], uint32(byteRate))
	binary.LittleEndian.PutUint16(h[32:], uint16(r.channels*2))
	binary.LittleEndian.PutUint16(h[34:], 16)
	copy(h[36:], "data")
	binary.LittleEndian.PutUint32(h[40:], uint32(r.bytes))
	r.f.WriteAt(h, 0)
}

// Close writes the final header and closes the file.
func (r *TxRecorder) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	r.writeHeader()
	err := r.f.Close()
	r.f = nil
	return err
}
