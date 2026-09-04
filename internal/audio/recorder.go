package audio

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Recorder writes receive audio to a WAV, and keeps a rolling replay buffer.
//
// ⚠️ EVERY REPORTED FIELD IS DERIVED FROM WHAT ACTUALLY HAPPENED. The reference
// implementation this is ported from answered {"status":"ok","recording":true}
// from /api/record/start while the recorder had failed to start - a 200 there
// meant the route existed, nothing more. If the file cannot be opened, recording
// is false and the reason is said out loud.
//
// ⚠️ THE REPLAY RING IS ALWAYS FILLING, recording or not. That is the whole
// point of it: the operator asks for the last 60 seconds AFTER hearing something
// worth keeping, and a buffer that only fills while recording could never
// answer that.
type Recorder struct {
	mu sync.Mutex

	dir      string
	rate     int
	channels int

	ring     []byte // the replay buffer, a fixed-size sliding window
	ringMax  int
	ringFull bool
	ringAt   int

	f        *os.File
	bytes    int
	name     string
	started  time.Time
	maxBytes int
	lastErr  string
}

func NewRecorder(dir string, rate, channels, replaySeconds, maxSeconds int) *Recorder {
	bytesPerSec := rate * channels * 2
	return &Recorder{
		dir: dir, rate: rate, channels: channels,
		ring:     make([]byte, bytesPerSec*replaySeconds),
		ringMax:  bytesPerSec * replaySeconds,
		maxBytes: bytesPerSec * maxSeconds,
	}
}

// Available reports whether recording could work at all, and why not if it
// cannot. ⚠️ Checked by actually creating the directory: a path that cannot be
// written is not a problem to discover halfway through an interesting contact.
func (r *Recorder) Available() (bool, string) {
	if r.dir == "" {
		return false, "no recording directory configured"
	}
	if err := os.MkdirAll(r.dir, 0o755); err != nil {
		return false, "cannot write to " + r.dir + ": " + err.Error()
	}
	return true, ""
}

func (r *Recorder) Recording() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.f != nil
}

// Feed takes raw PCM from the receive stream. It always fills the ring; it
// writes to the file only while recording.
func (r *Recorder) Feed(pcm []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// The ring is a plain sliding window, copied in two pieces when it wraps.
	//
	// ⚠️ IT WALKS A COPY OF THE SLICE HEADER, NOT pcm ITSELF. Consuming pcm here
	// left it empty for the file write below, so a recording ran with a healthy
	// "recording": true, a growing replay buffer and a 44-byte file containing
	// nothing but a WAV header. Found by MEASURING the file, not by reading the
	// status - which is the whole reason the tone source exists.
	rest := pcm
	if r.ringMax > 0 {
		for len(rest) > 0 {
			n := copy(r.ring[r.ringAt:], rest)
			rest = rest[n:]
			r.ringAt += n
			if r.ringAt >= r.ringMax {
				r.ringAt = 0
				r.ringFull = true
			}
		}
	}
	if r.f == nil {
		return
	}
	// ⚠️ A CEILING, AND IT STOPS RATHER THAN TRUNCATES. An unattended recorder
	// that runs for a week fills the disk the host needs to keep running.
	if r.maxBytes > 0 && r.bytes >= r.maxBytes {
		r.finishLocked()
		r.lastErr = "reached the maximum recording length and stopped"
		return
	}
	n, err := r.f.Write(pcm)
	if err != nil {
		r.finishLocked()
		r.lastErr = "writing stopped: " + err.Error()
		return
	}
	r.bytes += n
	r.writeHeaderLocked()
}

func (r *Recorder) Start() (string, error) {
	if ok, why := r.Available(); !ok {
		return "", fmt.Errorf("%s", why)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f != nil {
		return r.name, fmt.Errorf("already recording")
	}
	// MM-DD-YYYY in the name, because a person reads these.
	name := filepath.Join(r.dir, time.Now().Format("01-02-2006_150405")+".wav")
	f, err := os.Create(name)
	if err != nil {
		return "", fmt.Errorf("could not open %s: %w", name, err)
	}
	if _, err := f.Write(make([]byte, 44)); err != nil {
		f.Close()
		return "", err
	}
	r.f, r.name, r.bytes, r.started, r.lastErr = f, name, 0, time.Now(), ""
	return name, nil
}

func (r *Recorder) Stop() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return "", fmt.Errorf("not recording")
	}
	name := r.name
	r.finishLocked()
	return name, nil
}

// Replay writes whatever is in the ring to a file. ⚠️ It does NOT stop or
// disturb a recording in progress.
func (r *Recorder) Replay() (string, error) {
	if ok, why := r.Available(); !ok {
		return "", fmt.Errorf("%s", why)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.ringFull && r.ringAt == 0 {
		return "", fmt.Errorf("nothing has been received yet")
	}
	var pcm []byte
	if r.ringFull {
		pcm = append(pcm, r.ring[r.ringAt:]...) // oldest first
	}
	pcm = append(pcm, r.ring[:r.ringAt]...)

	name := filepath.Join(r.dir, time.Now().Format("01-02-2006_150405")+"_replay.wav")
	f, err := os.Create(name)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.Write(wavHeader(len(pcm), r.rate, r.channels)); err != nil {
		return "", err
	}
	if _, err := f.Write(pcm); err != nil {
		return "", err
	}
	return name, nil
}

func (r *Recorder) Status() map[string]any {
	ok, why := r.Available()
	r.mu.Lock()
	defer r.mu.Unlock()
	out := map[string]any{
		"available": ok,
		// ⚠️ Derived from the file handle, never from "did Start() get called".
		"recording": r.f != nil,
		"directory": r.dir,
	}
	if why != "" {
		out["message"] = why
	}
	if r.lastErr != "" {
		out["message"] = r.lastErr
	}
	if r.f != nil {
		out["filename"] = r.name
		out["seconds"] = r.bytes / (r.rate * r.channels * 2)
	}
	replay := r.ringAt
	if r.ringFull {
		replay = r.ringMax
	}
	out["replay_seconds"] = replay / (r.rate * r.channels * 2)
	return out
}

func (r *Recorder) finishLocked() {
	if r.f == nil {
		return
	}
	r.writeHeaderLocked()
	r.f.Close()
	r.f = nil
}

func (r *Recorder) writeHeaderLocked() {
	if r.f == nil {
		return
	}
	r.f.WriteAt(wavHeader(r.bytes, r.rate, r.channels), 0)
}

func wavHeader(dataBytes, rate, channels int) []byte {
	h := make([]byte, 44)
	copy(h[0:], "RIFF")
	binary.LittleEndian.PutUint32(h[4:], uint32(36+dataBytes))
	copy(h[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(h[16:], 16)
	binary.LittleEndian.PutUint16(h[20:], 1)
	binary.LittleEndian.PutUint16(h[22:], uint16(channels))
	binary.LittleEndian.PutUint32(h[24:], uint32(rate))
	binary.LittleEndian.PutUint32(h[28:], uint32(rate*channels*2))
	binary.LittleEndian.PutUint16(h[32:], uint16(channels*2))
	binary.LittleEndian.PutUint16(h[34:], 16)
	copy(h[36:], "data")
	binary.LittleEndian.PutUint32(h[40:], uint32(dataBytes))
	return h
}
