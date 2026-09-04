#!/usr/bin/env python3
"""Measure the dominant frequency of a WAV, with no dependencies.

⚠️ THIS EXISTS BECAUSE A WRONG SAMPLE RATE IS INVISIBLE TO EVERY OTHER CHECK.
A client that plays a 22050 Hz stream as if it were 44100 counts every packet,
meters a healthy level and draws a perfect bar. It just plays an octave high.
Packet counts, byte counts and level meters all read identical either way, so
the only thing that can tell them apart is measuring the pitch of what actually
came out of the sound device.

Usage: measure_pitch.py <wav> [expected_hz] [tolerance_pct]
Exits 1 if an expected frequency is given and the measurement misses it.
"""
import array
import cmath
import math
import sys
import wave


def goertzel(samples, rate, freq):
    """Energy at one frequency. Cheaper than a full FFT and needs no numpy."""
    n = len(samples)
    k = int(0.5 + n * freq / rate)
    w = 2 * math.pi * k / n
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    return abs(complex(s1 - s2 * cmath.exp(-1j * w)))


def dominant(samples, rate, lo=100, hi=5000):
    """Coarse scan then refine. Zero-crossing alone is fooled by any DC offset
    or noise; a scan of real energies is not."""
    best, best_e = 0, -1.0
    step = 25
    for f in range(lo, hi, step):
        e = goertzel(samples, rate, f)
        if e > best_e:
            best, best_e = f, e
    for f in range(max(lo, best - step), min(hi, best + step), 2):
        e = goertzel(samples, rate, f)
        if e > best_e:
            best, best_e = f, e
    return best


def main():
    path = sys.argv[1]
    expect = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    tol_pct = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0

    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    d = array.array("h", w.readframes(w.getnframes()))
    if ch > 1:
        d = d[::ch]  # one channel is enough; the tone is the same in both
    # A slice from the middle: the start can catch the stream still filling and
    # the end can catch it being torn down, and either would be measured as a
    # pitch that was never played.
    n = len(d)
    seg = d[n // 3: n // 3 + rate // 2] or d
    peak = max(abs(x) for x in seg) if seg else 0
    if peak < 200:
        print(f"FAIL: nothing came out of the sound device (peak {peak})")
        sys.exit(1)

    hz = dominant(list(seg), rate)
    print(f"measured {hz} Hz  (peak {peak}, {rate} Hz {ch}ch)")
    if not expect:
        return
    off = abs(hz - expect) * 100.0 / expect
    if off <= tol_pct:
        print(f"PASS: expected {expect} Hz, measured {hz} Hz ({off:.1f}% off)")
        return
    hint = ""
    # Name the fault rather than just the number: a factor of two is a rate
    # mismatch, and that is the whole reason this check exists.
    for factor, why in ((2.0, "the client is playing at DOUBLE the host's rate"),
                        (0.5, "the client is playing at HALF the host's rate")):
        if abs(hz - expect * factor) * 100.0 / expect < 12:
            hint = f" - {why}"
    print(f"FAIL: expected {expect} Hz, measured {hz} Hz ({off:.1f}% off){hint}")
    sys.exit(1)


if __name__ == "__main__":
    main()
