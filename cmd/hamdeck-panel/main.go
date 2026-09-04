// The panel, in Go.
//
// ⚠️ ONE LANGUAGE FOR THE WHOLE PRODUCT, WHICH IS THE POINT OF THIS BUILD. Gio
// draws with the GPU and targets Windows, macOS, Linux, iOS, Android and WASM
// from the same source - the same platform list as Flutter, without a second
// toolchain, a second language, or a 40 MB web bundle.
//
// ⚠️ AND IT IS AN EXPERIMENT BESIDE A WORKING PANEL, not a replacement for one.
// The Qt client is on four platforms and on the air; this talks to a simulated
// rig on a different port and cannot key anything.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"image"
	"image/color"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"gioui.org/app"
	"gioui.org/font/gofont"
	"gioui.org/layout"
	"gioui.org/op"
	"gioui.org/op/clip"
	"gioui.org/op/paint"
	"gioui.org/text"
	"gioui.org/unit"
	"gioui.org/widget"
	"gioui.org/widget/material"
)

// The instrument palette, the same tokens as the Qt client's Theme.qml - so a
// judgement about this build is about the platform, not about new paint.
var (
	ground  = color.NRGBA{R: 0x0E, G: 0x10, B: 0x13, A: 0xFF}
	panelBg = color.NRGBA{R: 0x17, G: 0x1A, B: 0x1F, A: 0xFF}
	lineCol = color.NRGBA{R: 0x2A, G: 0x30, B: 0x38, A: 0xFF}
	textCol = color.NRGBA{R: 0xE8, G: 0xEA, B: 0xED, A: 0xFF}
	dimCol  = color.NRGBA{R: 0x8A, G: 0x92, B: 0x9C, A: 0xFF}
	amber   = color.NRGBA{R: 0xFF, G: 0xB0, B: 0x20, A: 0xFF}
	cyan    = color.NRGBA{R: 0x3B, G: 0x82, B: 0xF6, A: 0xFF}
	txRed   = color.NRGBA{R: 0xB4, G: 0x23, B: 0x2A, A: 0xFF}
	okGreen = color.NRGBA{R: 0x32, G: 0xC7, B: 0x65, A: 0xFF}
)

type rigState struct {
	Freq   int64  `json:"freq"`
	Mode   string `json:"mode"`
	VFO    string `json:"vfo"`
	Power  int    `json:"power"`
	TX     bool   `json:"tx"`
	SMeter int    `json:"s_meter"`
}

type client struct {
	base, token string
	last        rigState
	lastGood    time.Time
	err         string
}

func (c *client) login(user, pass string) error {
	body := strings.NewReader(fmt.Sprintf(`{"username":%q,"password":%q}`, user, pass))
	r, err := http.Post(c.base+"/api/auth/login", "application/json", body)
	if err != nil {
		return fmt.Errorf("no reply from %s", c.base)
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return fmt.Errorf("invalid credentials")
	}
	var out struct{ Token string }
	b, _ := io.ReadAll(r.Body)
	json.Unmarshal(b, &out)
	c.token = out.Token
	return nil
}

// ⚠️ A FAILED READ LEAVES THE LAST ONE AND MARKS IT OLD. It never invents a
// frequency: the Qt client's own history has a status route that returned a
// plausible value and sent an evening of debugging to the wrong end of the chain.
func (c *client) poll() {
	r, err := http.Get(c.base + "/api/status?token=" + c.token)
	if err != nil {
		return
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return
	}
	var s rigState
	b, _ := io.ReadAll(r.Body)
	if json.Unmarshal(b, &s) == nil {
		c.last, c.lastGood = s, time.Now()
	}
}

func (c *client) stale() bool { return time.Since(c.lastGood) > 3*time.Second }

func (c *client) send(path string) {
	req, _ := http.NewRequest("GET", c.base+path+"?token="+c.token, nil)
	if r, err := http.DefaultClient.Do(req); err == nil {
		r.Body.Close()
	}
	c.poll()
}

func freqText(hz int64) string {
	if hz <= 0 {
		return "—.———.———"
	}
	s := fmt.Sprintf("%09d", hz)
	return fmt.Sprintf("%s.%s.%s",
		strings.TrimLeft(s[:len(s)-6], "0")+"", s[len(s)-6:len(s)-3], s[len(s)-3:])
}

func main() {
	host := flag.String("host", "", "host:port of the HamDeck Go server")
	user := flag.String("user", "", "username")
	pass := flag.String("password", "", "password")
	flag.Parse()

	base := defaultBase()
	if *host != "" {
		base = "http://" + *host
	}
	c := &client{base: base}

	// ⚠️ SERVED BY THE HOST, SO ASK BEFORE ASKING. In a browser the session is a
	// same-origin cookie the page already carries, and requests from here send it
	// automatically - so a panel that opened a login screen at somebody who was
	// already logged in would be demanding a password it did not need. One
	// unauthenticated poll answers the question; if it comes back, we are in.
	if base != "" && *user == "" {
		c.poll()
		if !c.stale() {
			go func() {
				for range time.Tick(500 * time.Millisecond) {
					c.poll()
				}
			}()
		}
	}
	// ⚠️ In the browser the session comes from a cookie the page already holds
	// after login, so the panel polls with no credentials of its own until it is
	// told some. On a desktop the flags provide them.
	if base != "" && *user != "" {
		if err := c.login(*user, *pass); err != nil {
			c.err = err.Error()
		} else {
			c.poll()
			go func() {
				for range time.Tick(500 * time.Millisecond) {
					c.poll()
				}
			}()
		}
	}

	// ⚠️ NO HEADLESS RENDER HERE YET, AND IT IS A REAL GAP. This machine has no
	// display, so nothing local has LOOKED at this panel - it is verified in a
	// browser via the WASM build, which is not the same thing as the Qt client's
	// --check-resolutions walk. Say so rather than let a green build imply more.

	go func() {
		w := new(app.Window)
		w.Option(app.Title("HamDeck"), app.Size(unit.Dp(420), unit.Dp(760)))
		if err := loop(w, c); err != nil {
			log.Fatal(err)
		}
		os.Exit(0)
	}()
	app.Main()
}

func loop(w *app.Window, c *client) error {
	th := material.NewTheme()
	th.Shaper = text.NewShaper(text.WithCollection(gofont.Collection()))
	var ops op.Ops
	var ptt widget.Clickable
	// ⚠️ A LOGIN SCREEN, because the first version took credentials from
	// command-line FLAGS - which do not exist in a browser, so served as
	// WebAssembly it could never log in at all. It rendered a panel full of
	// dashes and looked like a design choice.
	var userEd, passEd widget.Editor
	var connectBtn widget.Clickable
	userEd.SingleLine, passEd.SingleLine = true, true
	passEd.Mask = 0x2022
	modes := []string{"LSB", "USB", "CW", "AM", "FM", "DATA"}
	clicks := make([]widget.Clickable, len(modes))

	go func() {
		for range time.Tick(250 * time.Millisecond) {
			w.Invalidate()
		}
	}()

	for {
		switch e := w.Event().(type) {
		case app.DestroyEvent:
			return e.Err
		case app.FrameEvent:
			gtx := app.NewContext(&ops, e)
			if c.token == "" && c.stale() {
				if connectBtn.Clicked(gtx) {
					c.err = ""
					if err := c.login(userEd.Text(), passEd.Text()); err != nil {
						c.err = err.Error()
					} else {
						// The password has been used; it does not stay in a field.
						passEd.SetText("")
						c.poll()
						go func() {
							for range time.Tick(500 * time.Millisecond) {
								c.poll()
								w.Invalidate()
							}
						}()
					}
				}
				drawLogin(gtx, th, c, &userEd, &passEd, &connectBtn)
				e.Frame(gtx.Ops)
				continue
			}
			if ptt.Clicked(gtx) {
				if c.last.TX {
					c.send("/api/ptt/off")
				} else {
					c.send("/api/ptt/on")
				}
			}
			for i := range clicks {
				if clicks[i].Clicked(gtx) {
					c.send("/api/mode/" + strings.ToLower(modes[i]))
				}
			}
			draw(gtx, th, c, &ptt, clicks, modes)
			e.Frame(gtx.Ops)
		}
	}
}

func fill(gtx layout.Context, col color.NRGBA) {
	paint.FillShape(gtx.Ops, col, clip.Rect{Max: gtx.Constraints.Max}.Op())
}

func draw(gtx layout.Context, th *material.Theme, c *client,
	ptt *widget.Clickable, clicks []widget.Clickable, modes []string) {
	fill(gtx, ground)
	inset := layout.UniformInset(unit.Dp(10))
	inset.Layout(gtx, func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
			// The readout
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return card(gtx, func(gtx layout.Context) layout.Dimensions {
					return layout.Flex{Axis: layout.Vertical, Alignment: layout.Middle}.Layout(gtx,
						layout.Rigid(func(gtx layout.Context) layout.Dimensions {
							l := material.Label(th, unit.Sp(40), freqText(c.last.Freq))
							// Greyed when old, never hidden: the operator must see
							// what it last was AND that it is old.
							l.Color = amber
							if c.stale() {
								l.Color = color.NRGBA{R: 0x8A, G: 0x63, B: 0x20, A: 0xFF}
							}
							return l.Layout(gtx)
						}),
						layout.Rigid(func(gtx layout.Context) layout.Dimensions {
							return layout.Flex{Spacing: layout.SpaceAround}.Layout(gtx,
								layout.Rigid(stat(th, "MODE", c.last.Mode)),
								layout.Rigid(stat(th, "VFO", c.last.VFO)),
								layout.Rigid(stat(th, "POWER", fmt.Sprintf("%d W", c.last.Power))),
							)
						}),
					)
				})
			}),
			layout.Rigid(layout.Spacer{Height: unit.Dp(8)}.Layout),
			// The meter
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return card(gtx, func(gtx layout.Context) layout.Dimensions {
					return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
						layout.Rigid(silk(th, "SIGNAL")),
						layout.Rigid(layout.Spacer{Height: unit.Dp(6)}.Layout),
						layout.Rigid(func(gtx layout.Context) layout.Dimensions {
							w := gtx.Constraints.Max.X
							h := gtx.Dp(unit.Dp(14))
							frac := float32(c.last.SMeter) / 255
							if c.stale() {
								frac = 0
							}
							paint.FillShape(gtx.Ops, panelBg,
								clip.UniformRRect(image.Rect(0, 0, w, h), 3).Op(gtx.Ops))
							paint.FillShape(gtx.Ops, okGreen,
								clip.UniformRRect(image.Rect(0, 0, int(float32(w)*frac), h), 3).Op(gtx.Ops))
							return layout.Dimensions{Size: image.Pt(w, h)}
						}),
					)
				})
			}),
			layout.Rigid(layout.Spacer{Height: unit.Dp(8)}.Layout),
			// Mode keys
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return card(gtx, func(gtx layout.Context) layout.Dimensions {
					return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
						layout.Rigid(silk(th, "MODE")),
						layout.Rigid(layout.Spacer{Height: unit.Dp(8)}.Layout),
						layout.Rigid(func(gtx layout.Context) layout.Dimensions {
							var row []layout.FlexChild
							for i, m := range modes {
								i, m := i, m
								row = append(row, layout.Rigid(func(gtx layout.Context) layout.Dimensions {
									b := material.Button(th, &clicks[i], m)
									b.Background = panelBg
									b.Color = textCol
									// Lit from the RIG's reported mode, never from
									// the click - the same rule as every other
									// panel in this project.
									if c.last.Mode == m {
										b.Background = color.NRGBA{R: 0x1E, G: 0x3A, B: 0x6B, A: 0xFF}
										b.Color = cyan
									}
									b.Inset = layout.UniformInset(unit.Dp(10))
									return layout.Inset{Right: unit.Dp(6)}.Layout(gtx, b.Layout)
								}))
							}
							return layout.Flex{}.Layout(gtx, row...)
						}),
					)
				})
			}),
			layout.Flexed(1, layout.Spacer{}.Layout),
			// PTT
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				b := material.Button(th, ptt, map[bool]string{true: "ON AIR", false: "PTT"}[c.last.TX])
				b.Background = panelBg
				b.Color = textCol
				if c.last.TX {
					b.Background = txRed
					b.Color = color.NRGBA{R: 255, G: 255, B: 255, A: 255}
				}
				b.Inset = layout.UniformInset(unit.Dp(18))
				return b.Layout(gtx)
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				msg := fmt.Sprintf("connected · %d/255 raw", c.last.SMeter)
				col := dimCol
				if c.err != "" {
					msg, col = c.err, txRed
				} else if c.stale() {
					msg, col = "⚠ no reply from the host — showing the last reading", amber
				}
				l := material.Label(th, unit.Sp(11), msg)
				l.Color = col
				return layout.Inset{Top: unit.Dp(6)}.Layout(gtx, l.Layout)
			}),
		)
	})
}

func card(gtx layout.Context, inner layout.Widget) layout.Dimensions {
	macro := op.Record(gtx.Ops)
	dims := layout.UniformInset(unit.Dp(12)).Layout(gtx, inner)
	call := macro.Stop()
	paint.FillShape(gtx.Ops, panelBg,
		clip.UniformRRect(image.Rect(0, 0, gtx.Constraints.Max.X, dims.Size.Y), 6).Op(gtx.Ops))
	paint.FillShape(gtx.Ops, lineCol,
		clip.Stroke{Path: clip.UniformRRect(image.Rect(0, 0, gtx.Constraints.Max.X, dims.Size.Y), 6).Path(gtx.Ops), Width: 1}.Op())
	call.Add(gtx.Ops)
	return layout.Dimensions{Size: image.Pt(gtx.Constraints.Max.X, dims.Size.Y)}
}

func stat(th *material.Theme, k, v string) layout.Widget {
	return func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Vertical, Alignment: layout.Middle}.Layout(gtx,
			layout.Rigid(silk(th, k)),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				l := material.Label(th, unit.Sp(16), v)
				l.Color = textCol
				return l.Layout(gtx)
			}),
		)
	}
}

func silk(th *material.Theme, s string) layout.Widget {
	return func(gtx layout.Context) layout.Dimensions {
		l := material.Label(th, unit.Sp(11), s)
		l.Color = dimCol
		return l.Layout(gtx)
	}
}


// The connect screen. ⚠️ No default host: the panel is served BY the station, so
// it already knows where it is (origin_js.go) - and a hostname compiled into a
// published client would point every install at one person's radio.
func drawLogin(gtx layout.Context, th *material.Theme, c *client,
	user, pass *widget.Editor, btn *widget.Clickable) layout.Dimensions {
	fill(gtx, ground)
	return layout.Center.Layout(gtx, func(gtx layout.Context) layout.Dimensions {
		gtx.Constraints.Max.X = gtx.Dp(unit.Dp(340))
		return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				l := material.Label(th, unit.Sp(30), "HAMDECK")
				l.Color = textCol
				return layout.Center.Layout(gtx, l.Layout)
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				l := material.Label(th, unit.Sp(11), "Go host · Gio panel — one language, top to bottom")
				l.Color = dimCol
				return layout.Center.Layout(gtx, l.Layout)
			}),
			layout.Rigid(layout.Spacer{Height: unit.Dp(18)}.Layout),
			layout.Rigid(field(th, "USERNAME", user)),
			layout.Rigid(layout.Spacer{Height: unit.Dp(10)}.Layout),
			layout.Rigid(field(th, "PASSWORD", pass)),
			layout.Rigid(layout.Spacer{Height: unit.Dp(14)}.Layout),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				b := material.Button(th, btn, "CONNECT")
				b.Background = color.NRGBA{R: 0x1E, G: 0x3A, B: 0x6B, A: 0xFF}
				b.Color = cyan
				b.Inset = layout.UniformInset(unit.Dp(14))
				return b.Layout(gtx)
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				if c.err == "" {
					return layout.Dimensions{}
				}
				// ⚠️ The host's own message, not "login failed": it separates a
				// bad password from a host that is not answering at all.
				l := material.Label(th, unit.Sp(12), c.err)
				l.Color = txRed
				return layout.Inset{Top: unit.Dp(12)}.Layout(gtx, l.Layout)
			}),
		)
	})
}

func field(th *material.Theme, label string, ed *widget.Editor) layout.Widget {
	return func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
			layout.Rigid(silk(th, label)),
			layout.Rigid(layout.Spacer{Height: unit.Dp(4)}.Layout),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				macro := op.Record(gtx.Ops)
				dims := layout.UniformInset(unit.Dp(11)).Layout(gtx, func(gtx layout.Context) layout.Dimensions {
					e := material.Editor(th, ed, "")
					e.Color = textCol
					return e.Layout(gtx)
				})
				call := macro.Stop()
				paint.FillShape(gtx.Ops, ground,
					clip.UniformRRect(image.Rect(0, 0, gtx.Constraints.Max.X, dims.Size.Y), 6).Op(gtx.Ops))
				paint.FillShape(gtx.Ops, lineCol,
					clip.Stroke{Path: clip.UniformRRect(image.Rect(0, 0, gtx.Constraints.Max.X, dims.Size.Y), 6).Path(gtx.Ops), Width: 1}.Op())
				call.Add(gtx.Ops)
				return layout.Dimensions{Size: image.Pt(gtx.Constraints.Max.X, dims.Size.Y)}
			}),
		)
	}
}
