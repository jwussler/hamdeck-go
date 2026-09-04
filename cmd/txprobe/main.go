// txprobe: send a known tone into a host's transmit path and ask what arrived.
//
// ⚠️ IT DOES NOT KEY THE RADIO. Audio reaching the codec is not transmission -
// the rig only puts it on the air when keyed - so this exercises the entire
// transmit audio path with no carrier. That distinction is what makes it safe to
// run against a live station.
//
// ⚠️ AND IT ASKS THE HOST WHAT LEVEL ARRIVED, rather than reporting that it sent
// something. "Frames were written" is exactly the reading that looks identical
// for a working microphone and a muted one.
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
)

func main() {
	host := flag.String("host", "", "host:port of the HamDeck Go server")
	user := flag.String("user", "admin", "username")
	pass := flag.String("password", "", "password")
	secs := flag.Int("seconds", 2, "how long a tone to send")
	flag.Parse()

	base := "http://" + *host
	body := strings.NewReader(fmt.Sprintf(`{"username":%q,"password":%q}`, *user, *pass))
	r, err := http.Post(base+"/api/auth/login", "application/json", body)
	if err != nil {
		log.Fatalf("login: %v", err)
	}
	var lr struct{ Token string }
	b, _ := io.ReadAll(r.Body)
	json.Unmarshal(b, &lr)
	if lr.Token == "" {
		log.Fatalf("login refused: %s", strings.TrimSpace(string(b)))
	}

	ctx := context.Background()
	conn, _, err := websocket.Dial(ctx, "ws://"+*host+"/ws/tx?token="+lr.Token, nil)
	if err != nil {
		log.Fatalf("transmit socket: %v", err)
	}
	defer conn.CloseNow()

	// The host names the format it wants. ⚠️ Using the receive rate here instead
	// would send the operator's voice at the wrong speed - on this codec capture
	// is 22050 and playback is 44100.
	_, hello, err := conn.Read(ctx)
	if err != nil {
		log.Fatalf("no format from the host: %v", err)
	}
	var f struct {
		Rate     int    `json:"rate"`
		Channels int    `json:"channels"`
		Format   string `json:"format"`
	}
	json.Unmarshal(hello, &f)
	fmt.Printf("  host wants: %d Hz, %d ch, %s\n", f.Rate, f.Channels, f.Format)

	// The radio's answer about its own routing, if the host sent one.
	ctx2, cancel := context.WithTimeout(ctx, 2*time.Second)
	if _, msg, err := conn.Read(ctx2); err == nil {
		fmt.Printf("  radio said: %s\n", msg)
	}
	cancel()

	// A 1 kHz tone at about a third of full scale.
	total := f.Rate * *secs
	const chunkFrames = 2048
	buf := make([]byte, chunkFrames*2*f.Channels)
	sent := 0
	for i := 0; i < total; i += chunkFrames {
		for j := 0; j < chunkFrames; j++ {
			v := int16(11000 * math.Sin(2*math.Pi*1000*float64(i+j)/float64(f.Rate)))
			for c := 0; c < f.Channels; c++ {
				binary.LittleEndian.PutUint16(buf[(j*f.Channels+c)*2:], uint16(v))
			}
		}
		if err := conn.Write(ctx, websocket.MessageBinary, buf); err != nil {
			log.Fatalf("write: %v", err)
		}
		sent += len(buf)
		time.Sleep(time.Duration(chunkFrames) * time.Second / time.Duration(f.Rate) / 2)
	}
	fmt.Printf("  sent %d bytes of 1 kHz\n", sent)

	// ⚠️ Ask the HOST what it measured. This is the whole point of the probe.
	time.Sleep(300 * time.Millisecond)
	req, _ := http.NewRequest("GET", base+"/api/audio?token="+lr.Token, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Fatalf("audio stats: %v", err)
	}
	var st struct {
		Tx map[string]any `json:"tx"`
	}
	sb, _ := io.ReadAll(resp.Body)
	json.Unmarshal(sb, &st)
	fmt.Printf("  host measured: peak %v (%v%%), frames %v, dropped %v\n",
		st.Tx["peak"], st.Tx["peak_pct"], st.Tx["frames_written"], st.Tx["dropped"])

	if p, ok := st.Tx["peak"].(float64); !ok || p == 0 {
		log.Fatal("SILENCE REACHED THE RADIO - the path accepted every frame and delivered nothing")
	}
	fmt.Println("  AUDIO REACHED THE RADIO")
}
