// HamDeck host, in Go.
//
// ⚠️ THIS IS AN EXPERIMENT RUNNING BESIDE A WORKING C++ HOST, NOT A REPLACEMENT.
// The station is on the air with the C++ one; this binds different ports, talks
// to a SIMULATED rig, and never opens the serial port or the codec - the radio is
// single-instance hardware and two hosts fighting for it is the one way this
// experiment could cost something real.
//
// What it is testing: whether Go's compatibility promise and a rig INTERFACE
// (rather than verbs hardcoded for one model) make this easier to keep alive for
// ten years by one person.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jwussler/hamdeck-go/internal/api"
	"github.com/jwussler/hamdeck-go/internal/audio"
	"github.com/jwussler/hamdeck-go/internal/auth"
	"github.com/jwussler/hamdeck-go/internal/catproxy"
	"github.com/jwussler/hamdeck-go/internal/rig"
	"github.com/jwussler/hamdeck-go/internal/tuner"
)

// Set by the build from the git tag. ⚠️ Not a literal: the C++ host reported
// 0.1.0 while its clients shipped 0.1.33, and the version is the first thing
// anybody asks for when something is wrong.
var version = "0.0.0-untagged"

const defaultUsersPath = "/etc/hamdeck-go/users.json"

func main() {
	// ⚠️ THE ACCOUNT COMMANDS COME FIRST, before flag parsing, because
	// `hamdeck-host users set wa0o` is a verb and a name, not flags - and this is
	// the path somebody takes when they are locked out and in a hurry. See
	// users.go. --users may precede it to point at another store.
	if len(os.Args) > 1 {
		args := os.Args[1:]
		path := defaultUsersPath
		if args[0] == "--users" || args[0] == "-users" {
			if len(args) < 2 {
				fmt.Fprintln(os.Stderr, "--users needs a path")
				os.Exit(2)
			}
			path, args = args[1], args[2:]
		}
		if len(args) > 0 && args[0] == "users" {
			os.Exit(usersCommand(auth.NewStore(path), args[1:]))
		}
	}

	control := flag.Int("control-port", 5101, "loopback control listener, no session")
	dash := flag.Int("port", 5102, "dashboard listener, session required")
	panel := flag.String("panel", "", "directory of a built panel to serve at /")
	panel2 := flag.String("panel-alt", "", "a second panel, served at /alt/ - for comparing two clients side by side")
	usersPath := flag.String("users", defaultUsersPath, "the accounts file. `hamdeck-host users set <name>` creates and resets accounts in it")
	showVer := flag.Bool("version", false, "print the version and exit")
	radioPort := flag.String("radio", "", "serial device of the radio, e.g. /dev/ttyRIG. Empty = simulated rig")
	radioBaud := flag.Int("radio-baud", 38400, "serial speed")
	pttTimeout := flag.Duration("ptt-timeout", 180*time.Second, "the transmit watchdog: the host unkeys the rig after this long, whatever the client is doing")
	audioList := flag.Bool("audio-list", false, "list the sound devices this machine has, by name")
	audioProbe := flag.String("audio-probe", "", "open the capture device matching this card name, read for 3s, and report the PEAK")
	catPort := flag.Int("cat-proxy-port", 0, "serve raw CAT to other software on 127.0.0.1:<port> (4532 is the usual choice). 0 = off")
	recDir := flag.String("record-dir", "", "directory for receive recordings. Empty = recording off")
	replaySecs := flag.Int("replay-seconds", 60, "how much receive audio to keep for /api/record/replay")
	recMaxSecs := flag.Int("record-max-seconds", 10800, "stop a recording after this long rather than filling the disk")
	txRecord := flag.String("tx-record", "", "TEST INSTRUMENT: write the audio clients transmit to this WAV file, with or without a sound card")
	txRate := flag.Int("tx-rate", 44100, "the rate the host asks clients to transmit at when --tx-record is used with no sound card. Deliberately unlike the receive rate: a client that reuses the receive rate is the bug this catches")
	tgxlHost := flag.String("tgxl", "", "antenna tuner host, e.g. 192.168.40.51. Empty = no tuner")
	tgxlPort := flag.Int("tgxl-port", 9010, "antenna tuner TCP port")
	audioDev := flag.String("audio", "", "capture device to stream from, matched by card name (e.g. codec). `tone:<hz>` streams a test tone instead of the radio. Empty = no audio")
	flag.Parse()

	if *showVer {
		fmt.Printf("HamDeck API (Go) %s\n", version)
		return
	}
	// ⚠️ THE RISKY PART, PROVEN BEFORE ANYTHING IS BUILT ON IT. Whether pure-Go
	// ALSA can actually read this station's codec decides the whole audio design,
	// and it is a ten minute answer rather than a discovery made after a
	// streaming path exists.
	if *audioList {
		devs, err := audio.List()
		if err != nil {
			log.Fatalf("cannot list sound devices: %v", err)
		}
		for _, d := range devs {
			fmt.Println("  " + d)
		}
		return
	}
	if *audioProbe != "" {
		desc, peak, err := audio.Probe(*audioProbe, 3*time.Second)
		if desc != "" {
			fmt.Println("device:", desc)
		}
		if err != nil {
			log.Fatalf("probe failed: %v", err)
		}
		pct := peak * 100 / 32767
		fmt.Printf("peak: %d/32767 (%d%%)\n", peak, pct)
		// ⚠️ Zero is a RESULT, not a pass. A capture that runs and returns
		// silence looks identical to one carrying the band, which is the trap
		// this whole project keeps re-learning.
		if peak == 0 {
			fmt.Println("SILENCE - the device opened and read frames, and every one of them was zero.")
			os.Exit(1)
		}
		fmt.Println("AUDIO IS ARRIVING")
		return
	}

	// ⚠️ A REAL RADIO IF ASKED FOR, AND IT FAILS RATHER THAN FALLING BACK. A host
	// that quietly runs the simulator when the port will not open comes up
	// looking healthy and reports a rig that is not there - the C++ host refuses
	// exactly this, for exactly this reason.
	var r rig.Rig
	if *radioPort != "" {
		if err := rig.SetPTTTimeout(*pttTimeout); err != nil {
			log.Fatalf("FATAL: %v", err)
		}
		log.Printf("transmit watchdog: %v", *pttTimeout)
		sr, err := rig.OpenSerial(*radioPort, *radioBaud)
		if err != nil {
			log.Fatalf("FATAL: %v - not falling back to the simulator, because a host "+
				"that reports a rig it cannot reach is worse than one that refuses to start", err)
		}
		defer sr.Close()
		r = sr
	} else {
		r = rig.NewSim()
	}
	// ⚠️ ONE PLACE ACCOUNTS EXIST: the store. No username in this file, no hash
	// in an environment variable. HAMDECK_ADMIN_HASH used to be read here and is
	// deliberately gone - two mechanisms that had to agree, and the one written
	// in Go could not be changed without a rebuild.
	store := auth.NewStore(*usersPath)
	a := auth.New(store, 480)
	if err := a.Load(); err != nil {
		// ⚠️ Refuse rather than start with no accounts. An unreadable file looks
		// exactly like a fresh install, and somebody "fixes" that by creating a
		// second administrator beside the accounts already on disk.
		log.Fatalf("FATAL: %v", err)
	}
	for _, w := range store.Warnings() {
		log.Printf("⚠️  %s", w)
	}
	// ⚠️ A RESET DONE FROM A TERMINAL MUST NOT NEED A RESTART. Restarting to
	// apply a password drops CAT, the receiver and anything on the air, so an
	// operator locked out mid-net would have to take the station down to get
	// back in. The file is checked every few seconds instead.
	go func() {
		for range time.Tick(3 * time.Second) {
			if changed, err := a.ReloadIfChanged(); err != nil {
				log.Printf("accounts: %v", err)
			} else if changed {
				log.Printf("accounts: reloaded %s", store.Path())
			}
		}
	}()

	// ⚠️ It starts WITHOUT a user rather than inventing one, and says so. A
	// shipped default credential is a credential everybody has.
	log.Printf("HamDeck API (Go) %s", version)
	log.Printf("rig: %s", r.Describe())
	if a.Configured() {
		log.Printf("accounts: %d in %s", len(a.Users()), store.Path())
	} else {
		// ⚠️ Never invent one. A shipped default credential is a credential
		// everybody has - but a host that only says "no users" is a dead end, so
		// it says the command that fixes it.
		log.Printf("⚠️  NO ACCOUNTS in %s - every login will be refused.", store.Path())
		log.Printf("    create one with:  hamdeck-host users set <username>")
	}

	// ⚠️ THE RECEIVER IS OPTIONAL AND ITS FAILURE IS LOUD. A host that starts
	// with a silent audio path looks healthy and is useless to a remote
	// operator, so this refuses to start rather than serving a panel that can
	// never make a sound.
	var stream *audio.Stream
	var txSink *audio.TxSink
	tone := false
	if *audioDev != "" {
		stream = audio.NewStream()
		// ⚠️ A test tone is announced loudly and takes no sound card. It is how a
		// client's playback is proved end to end - see Stream.StartTone - and it
		// must never be mistaken for the band.
		if hz, ok := strings.CutPrefix(*audioDev, "tone:"); ok {
			n, err := strconv.Atoi(hz)
			if err != nil {
				log.Fatalf("FATAL: audio: %q is not a frequency in Hz", hz)
			}
			if err := stream.StartTone(n); err != nil {
				log.Fatalf("FATAL: audio: %v", err)
			}
			log.Printf("audio in:  %s", stream.Describe())
			log.Printf("⚠️  THIS HOST IS STREAMING A TEST TONE, NOT THE RADIO.")
			tone = true
		} else if err := stream.Start(*audioDev); err != nil {
			log.Fatalf("FATAL: audio: %v", err)
		} else {
			log.Printf("audio in:  %s", stream.Describe())
		}

		// ⚠️ The transmit side is opened at startup too, and its failure is
		// reported rather than discovered mid-over by an operator whose voice
		// went nowhere.
		txSink = audio.NewTxSink()
		if tone {
			// Nothing to transmit into: a tone host has no sound card at all.
			txSink = nil
		} else if err := txSink.Open(*audioDev); err != nil {
			log.Printf("audio out: UNAVAILABLE - %v (receive still works; transmit will refuse)", err)
			txSink = nil
		} else {
			log.Printf("audio out: %s", txSink.Describe())
		}
	}

	// ⚠️ The recorder is fed from the SAME fan-out the listeners are, so a
	// recording is exactly what a listener heard rather than a second capture
	// that could differ.
	var recorder *audio.Recorder
	if *recDir != "" && stream != nil {
		recorder = audio.NewRecorder(*recDir, stream.Rate, stream.Channels,
			*replaySecs, *recMaxSecs)
		if ok, why := recorder.Available(); !ok {
			log.Fatalf("FATAL: --record-dir: %s", why)
		}
		stream.Record(recorder)
		log.Printf("recording: to %s, %ds replay buffer", *recDir, *replaySecs)
	} else if *recDir != "" {
		log.Printf("recording: IGNORED - there is no receive audio to record")
	}

	// ⚠️ THE POINT OF THIS: while the host holds the radio, nothing else can.
	// The proxy is what lets a logger, WSJT-X or contest software keep working
	// during a remote session instead of needing a virtual serial-port splitter.
	if *catPort != 0 {
		cr, ok := r.(catproxy.Rig)
		if !ok {
			log.Fatalf("FATAL: --cat-proxy-port needs a radio that accepts raw CAT; this one does not")
		}
		cp := catproxy.New(*catPort, cr)
		if err := cp.Start(); err != nil {
			log.Fatalf("FATAL: %v", err)
		}
		defer cp.Close()
		log.Printf("cat proxy: %s", cp.Describe())
		log.Printf("           N1MM: Configure Ports -> TCP -> 127.0.0.1:%d", *catPort)
		log.Printf("           ⚠️  anything that reaches that port can key the transmitter")
	}

	// ⚠️ THE TUNER DRIVES THE RADIO, not just the tuner: it drops to 15 W, goes
	// to CW, keys, tunes and puts everything back. It gets the rig for that
	// reason, and nothing else in this program hands the rig to anything.
	var tg *tuner.TGXL
	if *tgxlHost != "" {
		tg = tuner.New(*tgxlHost, *tgxlPort, tunerRig{r})
		log.Printf("tuner:     %s", tg.Describe())
	}

	// ⚠️ A TEST INSTRUMENT, and it says so out loud. It also makes the transmit
	// socket work with no sound card, which is the only way a client's transmit
	// path can be proved on a machine with no radio attached.
	var txRec *audio.TxRecorder
	if *txRecord != "" {
		rate, channels := *txRate, 1
		if txSink != nil {
			rate, channels = txSink.Rate(), txSink.Channels()
		}
		var err error
		txRec, err = audio.NewTxRecorder(*txRecord, rate, channels)
		if err != nil {
			log.Fatalf("FATAL: --tx-record: %v", err)
		}
		defer txRec.Close()
		log.Printf("⚠️  %s", txRec.Describe())
	}

	ctrl := &http.Server{
		Addr: fmt.Sprintf("127.0.0.1:%d", *control),
		Handler: (&api.Server{Rig: r, Auth: a, Version: version, Control: true,
			Audio: stream, Tx: txSink, TxRec: txRec, Tuner: asTuner(tg), Rec: recorder, Rig2: asRig2(r)}).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	pub := &http.Server{
		Addr: fmt.Sprintf(":%d", *dash),
		Handler: (&api.Server{Rig: r, Auth: a, Version: version,
			PanelDir: *panel, AltPanelDir: *panel2, Audio: stream,
			Tx: txSink, TxRec: txRec, Tuner: asTuner(tg), Rec: recorder, Rig2: asRig2(r)}).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("control  127.0.0.1:%d (loopback, no session)", *control)
		if err := ctrl.ListenAndServe(); err != nil {
			log.Fatalf("control listener: %v", err)
		}
	}()
	if *panel != "" {
		log.Printf("panel: serving %s at /", *panel)
	}
	log.Printf("dashboard :%d (session required)", *dash)
	if err := pub.ListenAndServe(); err != nil {
		log.Fatalf("dashboard listener: %v", err)
	}
}

// asRig2 exposes the transmit-routing methods only when the rig actually has
// them. ⚠️ The simulator does not, and giving it a fake that returns success
// would let a test pass on a path that cannot exist.
func asRig2(r rig.Rig) interface {
	SetRemoteTX(bool) error
	RemoteTXState() (bool, bool, error)
	SetPTT(bool) error
} {
	if sr, ok := r.(*rig.Serial); ok {
		return sr
	}
	return nil
}

// tunerRig is the small slice of the radio the tuner is allowed to touch.
//
// ⚠️ DELIBERATELY NARROW. The tuner changes power, mode and PTT and puts them
// back; handing it the whole Rig would let a future change reach further into
// the radio than the sequence has any business going.
type tunerRig struct{ r rig.Rig }

func (t tunerRig) Snapshot() (int, string) {
	s := t.r.Snapshot()
	return s.PowerW, s.Mode
}

func (t tunerRig) SetPower(w int) error {
	c, ok := t.r.(interface{ Send(string) error })
	if !ok {
		return fmt.Errorf("this radio does not accept a power command")
	}
	return c.Send(fmt.Sprintf("PC%03d;", w))
}

func (t tunerRig) SetMode(m string) error { return t.r.SetMode(m) }
func (t tunerRig) SetPTT(on bool) error   { return t.r.SetPTT(on) }

// asTuner keeps a nil tuner NIL through the interface.
//
// ⚠️ A typed nil in an interface is not nil, and the route would then call
// Configured() on a nil pointer and take the host down on the first click of a
// button the host does not even have.
func asTuner(t *tuner.TGXL) interface {
	Configured() bool
	Describe() string
	Active() bool
	Message() string
	Tune() error
	Stop()
} {
	if t == nil {
		return nil
	}
	return t
}
