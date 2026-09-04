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
	"github.com/jwussler/hamdeck-go/internal/rig"
)

// Set by the build from the git tag. ⚠️ Not a literal: the C++ host reported
// 0.1.0 while its clients shipped 0.1.33, and the version is the first thing
// anybody asks for when something is wrong.
var version = "0.0.0-untagged"

func main() {
	control := flag.Int("control-port", 5101, "loopback control listener, no session")
	dash := flag.Int("port", 5102, "dashboard listener, session required")
	panel := flag.String("panel", "", "directory of a built panel to serve at /")
	panel2 := flag.String("panel-alt", "", "a second panel, served at /alt/ - for comparing two clients side by side")
	hashPw := flag.Bool("hash-password", false, "read a password on stdin and print its hash")
	showVer := flag.Bool("version", false, "print the version and exit")
	radioPort := flag.String("radio", "", "serial device of the radio, e.g. /dev/ttyRIG. Empty = simulated rig")
	radioBaud := flag.Int("radio-baud", 38400, "serial speed")
	pttTimeout := flag.Duration("ptt-timeout", 180*time.Second, "the transmit watchdog: the host unkeys the rig after this long, whatever the client is doing")
	audioList := flag.Bool("audio-list", false, "list the sound devices this machine has, by name")
	audioProbe := flag.String("audio-probe", "", "open the capture device matching this card name, read for 3s, and report the PEAK")
	txRecord := flag.String("tx-record", "", "TEST INSTRUMENT: write the audio clients transmit to this WAV file, with or without a sound card")
	txRate := flag.Int("tx-rate", 44100, "the rate the host asks clients to transmit at when --tx-record is used with no sound card. Deliberately unlike the receive rate: a client that reuses the receive rate is the bug this catches")
	audioDev := flag.String("audio", "", "capture device to stream from, matched by card name (e.g. codec). `tone:<hz>` streams a test tone instead of the radio. Empty = no audio")
	flag.Parse()

	if *showVer {
		fmt.Printf("HamDeck API (Go) %s\n", version)
		return
	}
	if *hashPw {
		// ⚠️ stdin, never an argument - a password in argv is in the shell
		// history and visible in ps to every user on the machine.
		fmt.Fprint(os.Stderr, "New admin password: ")
		var pw string
		fmt.Scanln(&pw)
		if strings.TrimSpace(pw) == "" {
			fmt.Fprintln(os.Stderr, "no password given")
			os.Exit(1)
		}
		fmt.Printf("HAMDECK_ADMIN_HASH=%s\n", auth.Hash(pw))
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
	a := auth.New(480)
	if h := os.Getenv("HAMDECK_ADMIN_HASH"); h != "" {
		if err := a.AddUser("admin", h); err != nil {
			log.Fatalf("FATAL: %v", err)
		}
	}

	// ⚠️ It starts WITHOUT a user rather than inventing one, and says so. A
	// shipped default credential is a credential everybody has.
	log.Printf("HamDeck API (Go) %s", version)
	log.Printf("rig: %s", r.Describe())
	log.Printf("auth: %s", map[bool]string{
		true: "configured", false: "NO USERS - the dashboard will refuse every login",
	}[a.Configured()])

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
			Audio: stream, Tx: txSink, TxRec: txRec, Rig2: asRig2(r)}).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	pub := &http.Server{
		Addr: fmt.Sprintf(":%d", *dash),
		Handler: (&api.Server{Rig: r, Auth: a, Version: version,
			PanelDir: *panel, AltPanelDir: *panel2, Audio: stream,
			Tx: txSink, TxRec: txRec, Rig2: asRig2(r)}).Handler(),
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
