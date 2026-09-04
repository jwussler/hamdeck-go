#!/usr/bin/env bash
# Prove a desktop client's audio in BOTH directions, by pitch, with no radio.
#
# ⚠️ WHY PITCH AND NOT PACKET COUNTS. A client that gets the sample rate wrong
# counts every packet, meters a healthy level and draws a full bar. On receive it
# sounds an octave high; on transmit it puts the operator's voice on the air at
# half speed - transmitting fine, metering fine, unintelligible to everyone else.
# Every counter in this project reads identical either way. Measuring the pitch
# of what actually reached the sound device, and what actually reached the host,
# is the only check that can see it.
#
# The host deliberately sends receive at one rate and asks for transmit at
# ANOTHER, because a client that reuses the receive rate for transmit is the
# specific bug this exists to catch.
#
# Usage: tools/check_audio_roundtrip.sh <path-to-client-binary>
set -euo pipefail

CLIENT="${1:?usage: check_audio_roundtrip.sh <client binary>}"
RX_HZ=1000     # what the host streams
MIC_HZ=1500    # what the fake microphone emits
RX_RATE=22050  # the receive rate
TX_RATE=44100  # the transmit rate - deliberately NOT the receive rate
PORT=5902
DISP=":81"
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
    pkill -x hamdeck-host 2>/dev/null || true
    pkill -x "$(basename "$CLIENT")" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

command -v parecord >/dev/null || { echo "needs pulseaudio-utils"; exit 1; }
command -v xdotool  >/dev/null || { echo "needs xdotool"; exit 1; }

echo "== a virtual sound card: a speaker we can record, a mic that plays $MIC_HZ Hz"
pulseaudio --check || pulseaudio --start --exit-idle-time=-1
# ⚠️ Unload first. Loading these twice leaves two sinks named hdspk and one
# fake microphone feeding the sink nobody is recording, which reads as "the
# client transmitted silence" - a pass turning into a false failure on the
# second run of the day.
for m in $(pactl list short modules | grep -E "hdspk|hdmic|module-sine" | cut -f1); do
    pactl unload-module "$m" 2>/dev/null || true
done
pactl load-module module-null-sink sink_name=hdspk >/dev/null
pactl load-module module-null-sink sink_name=hdmic >/dev/null
pactl load-module module-sine sink=hdmic frequency=$MIC_HZ >/dev/null
pactl set-default-sink hdspk
pactl set-default-source hdmic.monitor

echo "== the fake microphone must itself be right before it can test anything"
timeout 3 parecord --device=hdmic.monitor --format=s16le --rate=44100 --channels=1 \
    --file-format=wav "$tmp/mic.wav" 2>/dev/null || true
python3 "$here/tools/measure_pitch.py" "$tmp/mic.wav" $MIC_HZ 5

echo "== host: streams $RX_HZ Hz, asks for transmit at $TX_RATE Hz"
[ -x "$here/hamdeck-host" ] || (cd "$here" && go build ./cmd/hamdeck-host)
HASH=$(echo "roundtrip" | "$here/hamdeck-host" --hash-password | sed 's/^HAMDECK_ADMIN_HASH=//')
HAMDECK_ADMIN_HASH="$HASH" "$here/hamdeck-host" --radio "" \
    --audio "tone:$RX_HZ" --tx-record "$tmp/tx.wav" --tx-rate $TX_RATE \
    --control-port 5901 --port $PORT >"$tmp/host.log" 2>&1 &
sleep 2

echo "== client"
Xvfb $DISP -screen 0 1100x950x24 >/dev/null 2>&1 &
sleep 2
DISPLAY=$DISP "$CLIENT" >"$tmp/client.log" 2>&1 &
sleep 6
export DISPLAY=$DISP
xdotool mousemove 640 300 click 1; sleep 0.5; xdotool type --delay 25 "http://127.0.0.1:$PORT"
xdotool mousemove 640 378 click 1; sleep 0.3; xdotool type --delay 25 "admin"
xdotool mousemove 640 456 click 1; sleep 0.3; xdotool type --delay 25 "roundtrip"
sleep 0.3; xdotool mousemove 640 526 click 1
sleep 7

echo "== RECEIVE: the pitch that came out of the sound device"
timeout 5 parecord --device=hdspk.monitor --format=s16le --rate=44100 --channels=2 \
    --file-format=wav "$tmp/rx.wav" 2>/dev/null || true
python3 "$here/tools/measure_pitch.py" "$tmp/rx.wav" $RX_HZ 5

echo "== TRANSMIT: arm, then the pitch that reached the host"
xdotool mousemove 65 582 click 1
sleep 6
python3 "$here/tools/measure_pitch.py" "$tmp/tx.wav" $MIC_HZ 5

echo "BOTH DIRECTIONS PASS"
