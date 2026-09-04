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
	audioList := flag.Bool("audio-list", false, "list the sound devices this machine has, by name")
	audioProbe := flag.String("audio-probe", "", "open the capture device matching this card name, read for 3s, and report the PEAK")
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

	r := rig.NewSim()
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

	ctrl := &http.Server{
		Addr:              fmt.Sprintf("127.0.0.1:%d", *control),
		Handler:           (&api.Server{Rig: r, Auth: a, Version: version, Control: true}).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	pub := &http.Server{
		Addr:              fmt.Sprintf(":%d", *dash),
		Handler: (&api.Server{Rig: r, Auth: a, Version: version,
			PanelDir: *panel, AltPanelDir: *panel2}).Handler(),
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
