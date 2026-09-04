# The SCU-LAN10, and why it is worth speaking its protocol

Researched 09/04/2026, after Joe: *"the whole scu10 thing sucks i dont have cat
control when i use it"*.

## The complaint is real and there is no official fix

The SCU-LAN10 takes the radio's USB. Yaesu's manual has **no virtual COM port and
no CAT passthrough**, and says outright that it "does not support ... digital mode
communication such as RTTY". So with the box plugged in you get Yaesu's app and
nothing else: no logger, no WSJT-X, no HamDeck.

## But the box re-exports everything on four UDP ports

From the reverse-engineered spec: CTRL, **CAT (port +1)**, AUDIO (port +2) and
**SCOPE (port +3)**. The CAT the radio is no longer giving you over USB is coming
back out of the box - it is just that only Yaesu's app listens to it.

## What nobody has built

Four independent efforts exist and every one of them is a REPLACEMENT PANEL:

| who | what | platform |
|---|---|---|
| CarrierWaveApp | "CW Sweep" + the MIT protocol spec (~76k packets, FTDX10) | macOS |
| michelemestre | "SCU LAN Remote" | Android |
| TJ1GD | "FT-710 Remote" - VFO, PTT, audio, scope, waterfall | Android |
| SLTPLAN | skips the box: waterfall off the radio's ACC SPI port, into wfview | hardware |

⚠️ **None of them hands CAT back to other software.** That is the hole, and this
project already has the other half of the answer: `cat_proxy.cpp` in the C++ host
is a loopback TCP CAT server written so "running N1MM alongside HamDeck" does not
need a virtual serial-port splitter. `cat_proxy_port` is sitting at 0 in the
station config.

## The chain that fixes it

    SCU-LAN10  ──UDP──>  HamDeck host  ──> the panel (CAT, audio, and a REAL waterfall)
                                       ──> loopback CAT port for N1MM / WSJT-X

The host's 127 API routes do not change. The radio moves from being on a serial
port to being behind a box, and everything above that stays where it is.

## What this station can contribute back

The spec's first open question: *"All current captures are FTDX10. Captures from
FTDX101MP/D or FT-710 would confirm the protocol is truly model-independent."*
This station is an FTDX-101MP.

And the scope packet reserves bytes 850-1699 for a second channel - the other
repo says explicitly it is reserved for the 101 series. The 101MP is a
dual-receiver radio, so it may well fill a region nobody has decoded. Two open
questions, one capture.

## Status here

- `internal/sculan` - framing, header, the gTable, encryption, auth body.
  ⚠️ Verified against the spec's own published 256 table values, and the test
  fails on demand when the formula is broken.
- `cmd/scudecode` - takes a pcap apart per channel and says whether the spectrum
  actually looks like spectrum, so a capture session is not wasted discovering at
  the desk that the scope was switched off.
- Not built: the session client. It cannot be written blind - the handshake has
  timing and constants that want a real box to answer.

⚠️ **The transport is obfuscation, not security**: the key travels in the header
of the packet it encrypts, there is no authentication and no replay protection.
Never expose it to the internet without a tunnel.
