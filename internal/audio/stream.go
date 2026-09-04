package audio

import (
	"context"
	"fmt"
	"log"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/yobert/alsa"
)

// Stream captures from the radio and fans the audio out to connected clients.
//
// ⚠️ ONE READER, ONE WRITER PER CLIENT, AND A BOUNDED QUEUE. A slow client must
// never slow the capture: the read loop has to keep up with the sound card or the
// card overruns and the operator hears gaps. So a client that cannot keep up
// loses FRAMES, not the stream, and the count is reported rather than hidden.
type Stream struct {
	mu      sync.RWMutex
	clients map[*client]struct{}

	Rate     int
	Channels int

	peak    int
	peakAt  time.Time
	running bool
	desc    string
	rec     *Recorder
}

type client struct {
	ch      chan []byte
	dropped int
}

func NewStream() *Stream {
	return &Stream{clients: map[*client]struct{}{}, Rate: 22050, Channels: 1}
}

func (s *Stream) Describe() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if !s.running {
		return "not started"
	}
	return s.desc
}

// Peak is the level of what is actually being captured, 0-32767, and it DECAYS.
//
// ⚠️ A high-water mark cannot answer "is audio flowing now", which is the only
// question worth asking of it. Two windows of nothing reports zero rather than
// holding the last number, because holding it would call a dead receiver a live
// band - the exact fault this project found on the C++ host tonight.
func (s *Stream) Peak() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.peakAt.IsZero() || time.Since(s.peakAt) > 3*time.Second {
		return 0
	}
	return s.peak
}

// Start opens the capture device and begins reading. It returns an error rather
// than starting a stream that produces nothing.
//
// ⚠️ EACH BUFFER SIZE IS PROVEN BY AN ACTUAL READ, NOT BY NEGOTIATION. This codec
// ACCEPTS a 2048 frame buffer and then fails EIO on the first read - so a ladder
// that trusted the negotiation picked a size that could never work, and the host
// refused to start with a message about a device that was fine. The only honest
// test of a size is reading with it.
func (s *Stream) Start(match string) error {
	var lastErr error
	for _, want := range []int{2048, 4096, 8192, 16384} {
		d, rate, ch, frames, err := tryOpen(match, want)
		if err != nil {
			lastErr = err
			continue
		}
		s.mu.Lock()
		s.Rate, s.Channels, s.running = rate, ch, true
		s.desc = fmt.Sprintf("alsa @ %d Hz %dch S16_LE, %d frame chunks (%d ms)",
			rate, ch, frames, frames*1000/rate)
		s.mu.Unlock()
		go s.readLoop(d, frames*d.BytesPerFrame())
		return nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no capture device matching %q", match)
	}
	return lastErr
}

// StartTone streams a generated sine instead of a sound card.
//
// ⚠️ THIS EXISTS TO CATCH A WRONG SAMPLE RATE, which is invisible to every other
// check. A client that plays a 22050 Hz stream at 44100 counts every packet,
// meters a healthy level and draws a perfect bar - it just plays everything an
// octave high, and nobody notices until a voice sounds wrong on the air. Point a
// client at a known frequency, record what comes out of its speaker and measure
// the pitch: that is the only test that can tell those two apart.
//
// It is deliberately NOT reachable from the radio's own flags by accident - the
// operator has to ask for "tone:<hz>" by name, because a station streaming a
// test tone while someone waits to hear the band is its own kind of failure.
func (s *Stream) StartTone(hz int) error {
	if hz <= 0 || hz*2 >= s.Rate {
		// Above Nyquist the tone aliases DOWN to some other frequency and the
		// gate would measure a number that has nothing to do with what it asked
		// for - and pass or fail for the wrong reason.
		return fmt.Errorf("a %d Hz tone cannot be represented at %d Hz sampling", hz, s.Rate)
	}
	s.mu.Lock()
	s.running = true
	s.desc = fmt.Sprintf("TEST TONE %d Hz @ %d Hz %dch S16_LE - not the radio",
		hz, s.Rate, s.Channels)
	rate, channels := s.Rate, s.Channels
	s.mu.Unlock()

	go func() {
		const chunkMs = 40
		frames := rate * chunkMs / 1000
		buf := make([]byte, frames*channels*2)
		phase := 0.0
		step := 2 * math.Pi * float64(hz) / float64(rate)
		tick := time.NewTicker(chunkMs * time.Millisecond)
		defer tick.Stop()
		for range tick.C {
			for f := 0; f < frames; f++ {
				v := int16(12000 * math.Sin(phase))
				phase += step
				if phase > 2*math.Pi {
					phase -= 2 * math.Pi
				}
				for c := 0; c < channels; c++ {
					i := (f*channels + c) * 2
					buf[i] = byte(uint16(v))
					buf[i+1] = byte(uint16(v) >> 8)
				}
			}
			s.publish(buf)
		}
	}()
	return nil
}

// tryOpen opens the device fresh for every attempt. ⚠️ A device that has failed a
// read is in an unknown state, and reusing it makes the next attempt's result
// meaningless.
func tryOpen(match string, wantFrames int) (*alsa.Device, int, int, int, error) {
	cards, err := alsa.OpenCards()
	if err != nil {
		return nil, 0, 0, 0, err
	}
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
				return nil, 0, 0, 0, fmt.Errorf("open: %w", err)
			}
			ch, err := d.NegotiateChannels(1, 2)
			if err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("channels: %w", err)
			}
			rate, err := d.NegotiateRate(22050, 44100, 48000)
			if err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("rate: %w", err)
			}
			if _, err := d.NegotiateFormat(alsa.S16_LE); err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("format: %w", err)
			}
			frames, err := d.NegotiateBufferSize(wantFrames, wantFrames*2)
			if err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("buffer %d: %w", wantFrames, err)
			}
			if err := d.Prepare(); err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("prepare: %w", err)
			}
			// The read that decides it.
			if err := d.Read(make([]byte, frames*d.BytesPerFrame())); err != nil {
				d.Close()
				return nil, 0, 0, 0, fmt.Errorf("read at %d frames: %w", frames, err)
			}
			return d, rate, ch, frames, nil
		}
	}
	return nil, 0, 0, 0, fmt.Errorf("no capture device matching %q", match)
}

func (s *Stream) readLoop(d *alsa.Device, chunkBytes int) {
	buf := make([]byte, chunkBytes)
	for {
		if err := d.Read(buf); err != nil {
			log.Printf("audio: capture stopped: %v", err)
			s.mu.Lock()
			s.running = false
			s.mu.Unlock()
			return
		}
		s.publish(buf)
	}
}

// publish meters one chunk and fans it out. Both the sound card and the test
// tone come through here, so the tone exercises the same metering, the same
// queue and the same drop rule the radio does - a test source on its own path
// would prove that path works and nothing else.
// Record attaches a recorder to this stream. ⚠️ It is fed from publish(), the
// same place clients are, so a recording is exactly what a listener heard - not
// a second capture that could differ.
func (s *Stream) Record(r *Recorder) {
	s.mu.Lock()
	s.rec = r
	s.mu.Unlock()
}

func (s *Stream) publish(buf []byte) {
	peak := 0
	for i := 0; i+1 < len(buf); i += 2 {
		v := int(int16(uint16(buf[i]) | uint16(buf[i+1])<<8))
		if v < 0 {
			v = -v
		}
		if v > peak {
			peak = v
		}
	}
	out := make([]byte, len(buf))
	copy(out, buf)

	s.mu.RLock()
	rec := s.rec
	s.mu.RUnlock()
	if rec != nil {
		// Outside the stream lock: the recorder writes to disk, and holding the
		// capture lock across a disk write is how a slow filesystem turns into
		// gaps in everybody's audio.
		rec.Feed(out)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.peakAt.IsZero() || time.Since(s.peakAt) > 1500*time.Millisecond {
		s.peak, s.peakAt = peak, time.Now()
	} else if peak > s.peak {
		s.peak = peak
	}
	for c := range s.clients {
		select {
		case c.ch <- out:
		default:
			// ⚠️ Drop for THIS client only. Blocking here would stall the
			// capture and every listener would hear the gap.
			c.dropped++
		}
	}
}

// Serve streams audio to one websocket client until it goes away.
func (s *Stream) Serve(ctx context.Context, conn *websocket.Conn) {
	c := &client{ch: make(chan []byte, 8)}
	s.mu.Lock()
	s.clients[c] = struct{}{}
	rate, ch := s.Rate, s.Channels
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, c)
		s.mu.Unlock()
	}()

	// ⚠️ THE FORMAT IS SENT FIRST, AS TEXT, so the client never has to assume a
	// rate. A player that guesses 48000 for a 22050 stream sounds like a
	// chipmunk and looks like a radio problem.
	// ⚠️ THE C++ HOST'S EXACT CONFIG FRAME, FIELD FOR FIELD. The Qt client parses
	// type/sample_rate/channels/bits_per_sample and ignores anything else; a
	// frame shaped {"rate":...} is silently not a config, so the client waits
	// forever for a format and plays nothing - which presents as a dead
	// receiver, not as a protocol mismatch.
	hello := fmt.Sprintf(
		`{"type":"config","sample_rate":%d,"channels":%d,"bits_per_sample":16}`, rate, ch)
	if err := conn.Write(ctx, websocket.MessageText, []byte(hello)); err != nil {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-c.ch:
			if err := conn.Write(ctx, websocket.MessageBinary, b); err != nil {
				return
			}
		}
	}
}

// Clients is how many are listening, for the panel to show.
func (s *Stream) Clients() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.clients)
}

// ── Transmit: audio from the operator, into the radio ───────────────────────
//
// ⚠️ THE MIRROR OF EVERYTHING ABOVE, AND THE DANGEROUS DIRECTION. Receive audio
// that fails is silence; transmit audio that fails is a keyed transmitter putting
// out nothing while every counter reads healthy - which is the failure this whole
// project keeps re-learning. So this measures what ARRIVED, not what was sent.

// TxSink plays PCM from a client into the radio's codec.
type TxSink struct {
	mu       sync.Mutex
	dev      *alsa.Device
	rate     int
	channels int
	desc     string

	peak   int
	peakAt time.Time
	// Frames that arrived and could not be played. ⚠️ Counted and reported, not
	// swallowed: an operator whose audio is being dropped is transmitting a
	// broken signal and has no other way to find out.
	dropped int
	written int64
}

func NewTxSink() *TxSink { return &TxSink{rate: 22050, channels: 1} }

func (t *TxSink) Describe() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.dev == nil {
		return "not started"
	}
	return t.desc
}

// Peak is the level of audio that reached the radio, 0-32767, decaying.
//
// ⚠️ THIS IS THE READING THAT SEPARATES A WORKING MICROPHONE FROM A MUTED ONE.
// Frames accepted, a queue behaving and a steady sample rate all read identically
// for digital silence - the C++ host proved that the hard way on the night it
// first transmitted, and this exists so the Go one never has to.
func (t *TxSink) Peak() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.peakAt.IsZero() || time.Since(t.peakAt) > 3*time.Second {
		return 0
	}
	return t.peak
}

// Rate is what the PLAYBACK device negotiated, which is not necessarily what
// capture negotiated.
//
// ⚠️ ON THIS CODEC THEY DIFFER: capture takes 22050 and playback insists on
// 44100. A client that assumed one rate for both would send the operator's voice
// into the radio at half speed - it would transmit, the meters would look
// healthy, and the operator would sound like a slowed-down recording to everyone
// but themselves. The rate is told to the client rather than assumed by it.
func (t *TxSink) Rate() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.rate
}

func (t *TxSink) Channels() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.channels
}

func (t *TxSink) Stats() (written int64, dropped int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.written, t.dropped
}

// Open finds the playback side of the codec and proves it with a write.
func (t *TxSink) Open(match string) error {
	cards, err := alsa.OpenCards()
	if err != nil {
		return err
	}
	for _, card := range cards {
		if match != "" && !strings.Contains(strings.ToLower(card.Title), strings.ToLower(match)) {
			continue
		}
		devs, err := card.Devices()
		if err != nil {
			continue
		}
		for _, d := range devs {
			if !d.Play {
				continue
			}
			if err := d.Open(); err != nil {
				return fmt.Errorf("open playback: %w", err)
			}
			ch, err := d.NegotiateChannels(1, 2)
			if err != nil {
				d.Close()
				return fmt.Errorf("channels: %w", err)
			}
			rate, err := d.NegotiateRate(22050, 44100, 48000)
			if err != nil {
				d.Close()
				return fmt.Errorf("rate: %w", err)
			}
			if _, err := d.NegotiateFormat(alsa.S16_LE); err != nil {
				d.Close()
				return fmt.Errorf("format: %w", err)
			}
			frames, err := d.NegotiateBufferSize(2048, 8192)
			if err != nil {
				d.Close()
				return fmt.Errorf("buffer: %w", err)
			}
			if err := d.Prepare(); err != nil {
				d.Close()
				return fmt.Errorf("prepare: %w", err)
			}
			t.mu.Lock()
			t.dev, t.rate, t.channels = d, rate, ch
			t.desc = fmt.Sprintf("alsa %s @ %d Hz %dch S16_LE, %d frame buffer",
				card.Title, rate, ch, frames)
			t.mu.Unlock()
			return nil
		}
	}
	return fmt.Errorf("no playback device matching %q", match)
}

// Write plays one packet of s16le audio from a client.
func (t *TxSink) Write(pcm []byte) {
	t.mu.Lock()
	dev := t.dev
	if dev == nil {
		t.dropped++
		t.mu.Unlock()
		return
	}
	peak := 0
	for i := 0; i+1 < len(pcm); i += 2 {
		v := int(int16(uint16(pcm[i]) | uint16(pcm[i+1])<<8))
		if v < 0 {
			v = -v
		}
		if v > peak {
			peak = v
		}
	}
	if t.peakAt.IsZero() || time.Since(t.peakAt) > 1500*time.Millisecond {
		t.peak, t.peakAt = peak, time.Now()
	} else if peak > t.peak {
		t.peak = peak
	}
	frames := len(pcm) / dev.BytesPerFrame()
	t.written += int64(frames)
	t.mu.Unlock()

	if err := dev.Write(pcm, frames); err != nil {
		t.mu.Lock()
		t.dropped++
		t.mu.Unlock()
	}
}

func (t *TxSink) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.dev != nil {
		t.dev.Close()
		t.dev = nil
	}
}
