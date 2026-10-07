#!/usr/bin/env python3
"""Synthesise the addon's own sounds: sound/bmx/*.wav.

    python3 tools/sound/make_sounds.py            # writes sound/bmx/

Nothing here is sampled or lifted from anywhere: every file is computed from
the physics of the thing it is, so the result is original work under the
repository's own licence (see sound/bmx/LICENSE.txt). Re-running writes
byte-identical files (the noise is seeded).

THE BELL is a bicycle "ding" bell: a thin steel dome struck by a sprung hammer.
A struck shell rings in a few INHARMONIC partials (not a musical tone's 1, 2, 3)
-- for a shallow dome about 1 : 2.7 : 5.1 : 8.3 -- each decaying at its own rate,
the higher ones faster. What makes a real bell shimmer instead of beep is that
every partial is a DOUBLET: the dome is not perfectly round, so each mode splits
into two a few hertz apart and the two beat against each other. The hammer is a
2 ms click of filtered noise on top. One press is "ring-ring": the lever's
thumb throw strikes twice, the second strike a little softer and a little off
the first one's spot, so its partials are weighted differently.

THE HORN (motorbikes) is an electric disc horn: a diaphragm buzzing at ~410 Hz,
which is a rich sawtooth-like wave, through a horn's resonance near 2.4 kHz,
with a twin a minor third up as on a two-tone horn.
"""
import math
import os
import struct
import sys
import wave

import numpy as np

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "sound", "bmx")


def write(name, x):
    x = np.asarray(x, dtype=np.float64)
    peak = np.max(np.abs(x))
    if peak > 0:
        x = x / peak * 0.89          # -1 dBFS
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print("wrote", os.path.relpath(path), f"{len(x) / RATE:.2f}s")


def onepole_hp(x, fc):
    a = math.exp(-2 * math.pi * fc / RATE)
    y = np.zeros_like(x)
    prev_x = prev_y = 0.0
    for i, v in enumerate(x):
        prev_y = a * (prev_y + v - prev_x)
        prev_x = v
        y[i] = prev_y
    return y


def biquad_bp(x, fc, q):
    w0 = 2 * math.pi * fc / RATE
    alpha = math.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


# The dome's modes: (ratio to the lowest, amplitude, decay time s, doublet split Hz)
DOME = [
    (1.000, 1.00, 1.15, 3.2),
    (2.712, 0.55, 0.62, 5.5),
    (5.104, 0.26, 0.30, 8.5),
    (8.310, 0.12, 0.16, 13.0),
    (11.92, 0.05, 0.09, 18.0),
]


def strike(n, f1, strength, spot, rng):
    """One hammer strike on the dome, `n` samples long."""
    t = np.arange(n) / RATE
    y = np.zeros(n)
    for i, (ratio, amp, tau, split) in enumerate(DOME):
        f = f1 * ratio
        # Where the hammer lands weights the modes: off the rim the higher
        # ones get more (spot 0..1), and a harder strike brightens it too.
        a = amp * (1 + spot * 0.6 * i) * (0.7 + 0.3 * strength) ** i
        ph1, ph2 = rng.uniform(0, 2 * math.pi, 2)
        env = np.exp(-t / (tau * (0.9 + 0.2 * strength)))
        y += a * env * (np.sin(2 * math.pi * (f - split / 2) * t + ph1)
                        + 0.3 * np.sin(2 * math.pi * (f + split / 2) * t + ph2))
    # A soft attack (the hammer is in contact ~0.4 ms), so no DC click.
    att = np.minimum(1, t / 0.0004)
    y *= att
    # The hammer's click: 2 ms of bright noise.
    m = int(0.0025 * RATE)
    click = rng.standard_normal(m) * np.exp(-np.arange(m) / (0.0006 * RATE))
    click = onepole_hp(click, 3500)
    y[:m] += click * 0.35 * strength
    return y * strength


def bell(variant):
    rng = np.random.default_rng(1000 + variant)
    f1 = [2290.0, 2245.0, 2335.0][variant - 1]      # a 55 mm steel dome
    dur = 1.7
    n = int(dur * RATE)
    y = np.zeros(n)
    # ring-ring: the second strike a beat after the first
    gap = [0.150, 0.138, 0.162][variant - 1]
    y += strike(n, f1, 1.0, 0.25, rng)
    o = int(gap * RATE)
    # The hammer meets the dome and damps what is ringing for an instant before
    # it springs off: that dip is what makes two dings and not one long one.
    ramp = int(0.004 * RATE)
    y[o:o + ramp] *= np.linspace(1, 0.12, ramp)
    y[o + ramp:] *= 0.12
    y[o:] += strike(n - o, f1, 0.95, 0.55, rng)
    # A fade at the very end so nothing is cut off mid-wave.
    tail = int(0.08 * RATE)
    y[-tail:] *= np.linspace(1, 0, tail)
    return y


def horn(variant):
    rng = np.random.default_rng(2000 + variant)
    dur = 0.55
    n = int(dur * RATE)
    t = np.arange(n) / RATE
    y = np.zeros(n)
    for f0, amp in ((410.0, 1.0), (488.0, 0.8)):
        f = f0 * (1 + 0.004 * (variant - 2))
        # a buzzing diaphragm: a band-limited sawtooth with a little jitter
        jitter = 1 + 0.002 * np.cumsum(rng.standard_normal(n)) / math.sqrt(n)
        ph = 2 * math.pi * np.cumsum(f * jitter) / RATE
        saw = np.zeros(n)
        k = 1
        while f * k < 9000:
            saw += np.sin(k * ph) / k
            k += 1
        y += amp * saw
    y = 0.6 * biquad_bp(y, 2400, 2.2) + 0.4 * biquad_bp(y, 900, 1.2)
    env = np.minimum(1, t / 0.012) * np.minimum(1, (dur - t) / 0.05)
    return y * env


def main():
    os.makedirs(OUT, exist_ok=True)
    for v in (1, 2, 3):
        write(f"bell{v}.wav", bell(v))
    for v in (1, 2):
        write(f"horn{v}.wav", horn(v))


if __name__ == "__main__":
    sys.exit(main())
