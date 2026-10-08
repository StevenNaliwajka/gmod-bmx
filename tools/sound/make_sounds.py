#!/usr/bin/env python3
"""Synthesise the addon's own sounds: sound/bmx/*.wav.

    python3 tools/sound/make_sounds.py            # writes sound/bmx/

Nothing here is sampled or lifted from anywhere: every file is computed from
the physics of the thing it is, so the result is original work under the
repository's own licence (see sound/bmx/LICENSE.txt). Re-running writes
byte-identical files (the noise is seeded).

THE BELL is the small, bright "ting" lever bell: a thin, shallow steel dome
about 35 mm across, struck by a sprung hammer. The owner picked the sound
("Bicycle bell 4", Picture to sound, YouTube AsyX2Dbcfjw), and every number in
TING below was MEASURED off that recording: the partials, their levels at the
strike and how fast each one dies away. The audio itself is not used. What it
showed:
  - The bell is not a low "ring" but a high one. Its strongest partial is near
    10.2 kHz, with a few weaker ones down to 1.56 kHz that carry the tail.
  - Every partial is a DOUBLET. The dome is not perfectly round, so each mode
    splits in two and they beat; at 10.2 kHz the twin is about 32 Hz up and
    17 dB down, which is the shimmer.
  - The higher partials die very quickly (10.2 kHz in about 70 ms, 14.4 kHz in
    40 ms), and the low ones ring on for most of a second. That is why it goes
    "ting" and then hums.
  - One press is FOUR hits, not two. The thumb throws the lever twice. Each throw
    is a strike, and then the hammer bounces back off its spring and hits again
    50-140 ms later. The two throws are about 0.25-0.3 s apart. The four variants
    follow the four presses on the recording, each with its own hit timing.

THE HORN (motorbikes) is an electric disc horn: a diaphragm buzzing at ~410 Hz,
which is a rich sawtooth-like wave, through a horn's resonance near 2.4 kHz,
with a twin a minor third up as on a two-tone horn.

THE LOOPS (engines, the motor, tyres) are built to repeat seamlessly. Each is a
whole number of cycles long and filtered CIRCULARLY (in the frequency domain),
so the last sample flows into the first. Each carries a WAV `cue ` chunk at
sample 0, which is how Source knows to loop a file. Their pitch follows the
rpm or the speed in game, so each file states the rpm it was made at, and
sh_sound.lua's `baseRpm` says the same:
  engine_4t   the dirt bike: a 450 cc four-stroke single at 5040 rpm. It fires
              once every TWO turns, so 42 bangs a second, each a pressure pulse
              through the header and the silencer's resonances.
  engine_2t   the moped: a 50 cc two-stroke at 4200 rpm. It fires every turn,
              70 Hz, through an expansion chamber, which gives the nasal
              "ring-ding".
  motor       an e-bike's hub motor and the e-moto's: the three-phase whine (the
              electrical frequency and its 3rd and 6th harmonics), a gear mesh
              above it, and a little bearing hiss.
  roll_tyre   a bicycle tyre on tarmac: low tread hum and road noise.
  roll_wheel  hard urethane wheels on concrete (board, scooter, skates): a
              brighter grit with the texture of the surface in it.

THE FREEWHEEL TICK is one pawl snapping over a ratchet tooth: a click of
filtered noise and the hub shell's ring. There are three, so a coasting tick is
never one file repeated, and a loop of them (freewheel) for when they come too
fast to hear apart.

THE BIKE'S OTHER NOISES: the chain over the chainring while the cranks turn
(chain, a loop), a derailleur shifting (shift), the chain slapping the stay on a
landing (chainslap), and the kickstand going down and up. Each is a few metal
modes rung by short hits at the times the mechanism makes them.
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


def write(name, x, loop=False, level=0.89):
    """`level` is the peak, linear: 0.89 is -1 dBFS; the loops sit lower, since they
    play under everything else."""
    x = np.asarray(x, dtype=np.float64)
    peak = np.max(np.abs(x))
    if peak > 0:
        x = x / peak * level
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    if loop:
        add_loop_cue(path)
    print("wrote", os.path.relpath(path), f"{len(x) / RATE:.2f}s", "(loop)" if loop else "")


def add_loop_cue(path):
    """Append a `cue ` chunk with one cue at sample 0. Source loops a WAV that has
    a cue point from that point to the end; without one it plays once and stops."""
    with open(path, "rb") as f:
        data = bytearray(f.read())
    cue = struct.pack("<4sI", b"cue ", 4 + 24) + struct.pack("<I", 1) \
        + struct.pack("<II4sIII", 1, 0, b"data", 0, 0, 0)
    data += cue
    struct.pack_into("<I", data, 4, len(data) - 8)
    with open(path, "wb") as f:
        f.write(data)


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


# --------------------------------------------------------------------------- bell

# The dome's partials, measured (see the header):
#   (frequency Hz, level dB at the strike, decay time s, doublet split Hz, twin's level)
TING = [
    (1564.5, -48.0, 0.71, 4.0, 0.30),
    (1649.0, -50.0, 0.79, 4.0, 0.30),
    (3848.0, -30.0, 0.40, 6.0, 0.25),
    (6603.0, -33.0, 0.21, 9.0, 0.25),
    (6714.0, -28.0, 0.18, 9.0, 0.25),
    (10031.0, -22.0, 0.072, 18.0, 0.20),
    (10231.0, -12.0, 0.065, 32.0, 0.15),
    (14390.0, -23.0, 0.040, 30.0, 0.20),
]

# Each press: (seconds after the first hit, strength 0..1). From the recording's
# four presses: a throw and its bounce, then the second throw and its bounce.
PRESSES = [
    [(0.000, 0.62), (0.120, 0.80), (0.288, 0.55), (0.352, 1.00)],
    [(0.000, 0.85), (0.136, 0.70), (0.180, 1.00)],
    [(0.000, 0.80), (0.052, 0.85), (0.232, 0.90), (0.276, 1.00)],
    [(0.000, 0.60), (0.120, 0.75), (0.256, 0.62), (0.304, 1.00)],
]


def ting(n, strength, rng):
    """One hammer hit on the dome, `n` samples long."""
    t = np.arange(n) / RATE
    y = np.zeros(n)
    for f, db, tau, split, twin in TING:
        # Where the hammer lands moves the balance between the modes a little from
        # hit to hit (+-1.5 dB), and a harder hit is brighter.
        a = 10 ** ((db + rng.uniform(-1.5, 1.5)) / 20) * strength ** (1 + f / 12000)
        ph1, ph2 = rng.uniform(0, 2 * math.pi, 2)
        env = np.exp(-t / tau)
        y += a * env * (np.sin(2 * math.pi * (f - split / 2) * t + ph1)
                        + twin * np.sin(2 * math.pi * (f + split / 2) * t + ph2))
    # The hammer is in contact for about 0.2 ms: a fast but not instant attack.
    y *= np.minimum(1, t / 0.0002)
    # The hammer's tick on top: 1.5 ms of bright noise.
    m = int(0.0015 * RATE)
    click = rng.standard_normal(m) * np.exp(-np.arange(m) / (0.0004 * RATE))
    click = onepole_hp(click, 6000)
    y[:m] += click * 0.05 * strength
    return y


def bell(variant):
    rng = np.random.default_rng(1000 + variant)
    hits = PRESSES[variant - 1]
    dur = hits[-1][0] + 1.25
    n = int(dur * RATE)
    y = np.zeros(n)
    for when, s in hits:
        o = int(when * RATE)
        if o > 0:
            # The hammer meets a dome that is still ringing and damps it for the
            # instant it touches: a short dip before the new hit, which is what
            # makes each hit read as its own and not as one long ring getting louder.
            d = int(0.0015 * RATE)
            y[o - d:o] *= np.linspace(1, 0.55, d)
            y[o:] *= 0.55
        y[o:] += ting(n - o, s, rng)
    tail = int(0.10 * RATE)
    y[-tail:] *= np.linspace(1, 0, tail) ** 2
    return y


# --------------------------------------------------------------------------- horn

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


# --------------------------------------------------------------------------- loops

def circular(x, shape):
    """Filter a loop in the frequency domain, so it stays seamless. `shape(f)` is
    the gain at each frequency."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / RATE)
    return np.fft.irfft(X * shape(f), len(x))


def resonance(f, fc, q, gain=1.0):
    """The magnitude of a resonance at fc with quality q, at the frequencies f."""
    r = f / fc
    return gain / np.sqrt((1 - r * r) ** 2 + (r / q) ** 2)


def engine(period, cycles, seed, res, strokes, rasp):
    """A single-cylinder engine loop: one pressure pulse per firing, `period`
    samples apart, through the exhaust's resonances `res` [(fc, q, gain)]. Each
    bang differs a little in strength and in timing, which is what makes a real
    engine sound alive and a pulse train sound like a buzzer. `rasp` adds the
    broadband roughness of the gas leaving the port."""
    rng = np.random.default_rng(seed)
    n = period * cycles
    x = np.zeros(n)
    for c in range(cycles):
        at = c * period + int(rng.normal(0, period * 0.012))
        amp = 1 + rng.normal(0, 0.09)
        # The pulse: a sharp rise and a ~2 ms fall, the gas leaving the exhaust port.
        m = int(0.004 * RATE)
        p = np.exp(-np.arange(m) / (0.0012 * RATE)) * amp
        for i in range(m):
            x[(at + i) % n] += p[i]
        # A four-stroke's other turn: the valve train and the intake, much softer,
        # half a cycle on.
        if strokes == 4:
            x[(at + period // 2) % n] += 0.12 * amp
    noise = rng.standard_normal(n)
    # The noise rides the bangs: loud right after each, quiet between.
    env = np.zeros(n)
    for c in range(cycles):
        at = c * period
        m = period // 2
        env[[(at + i) % n for i in range(m)]] += np.exp(-np.arange(m) / (period * 0.15))
    x = x + rasp * noise * env

    def shape(f):
        g = np.zeros_like(f)
        for fc, q, gain in res:
            g += resonance(f, fc, q, gain)
        # Nothing below 25 Hz (the speaker cannot) and the air rounds off the top.
        return g * (f > 25) / (1 + (f / 6000) ** 2)
    return circular(x, shape)


def engine_4t():
    # 5040 rpm, fires every other turn: 42 Hz, a 1050-sample period; 84 bangs is 2 s.
    return engine(1050, 84, 3001, [(95, 1.4, 1.0), (240, 2.5, 0.8), (620, 3.0, 0.45),
                                   (1450, 2.5, 0.18), (3200, 2.0, 0.06)], 4, 0.35)


def engine_2t():
    # 4200 rpm, fires every turn: 70 Hz, a 630-sample period; 140 bangs is 2 s.
    return engine(630, 140, 3002, [(180, 2.0, 0.5), (520, 4.0, 0.9), (1100, 5.0, 0.7),
                                   (2300, 3.5, 0.35), (4200, 2.5, 0.12)], 2, 0.6)


def motor():
    """The electric whine, 2 s. Every tone is a multiple of 0.5 Hz, so each one
    fits the loop a whole number of times."""
    rng = np.random.default_rng(3003)
    n = 2 * RATE
    t = np.arange(n) / RATE
    y = np.zeros(n)
    f0 = 400.0                     # the electrical frequency at the file's speed
    for mult, amp in ((1, 0.55), (2, 0.18), (3, 0.30), (6, 0.22), (9, 0.06), (12, 0.08)):
        y += amp * np.sin(2 * math.pi * f0 * mult * t + rng.uniform(0, 2 * math.pi))
    # The cogging of the magnets over the slots: a slow wobble in the whine.
    y *= 1 + 0.08 * np.sin(2 * math.pi * 12.5 * t)
    # The gear mesh of a geared hub, an inharmonic tone above.
    y += 0.16 * np.sin(2 * math.pi * 1736.5 * t) * (1 + 0.3 * np.sin(2 * math.pi * 6.5 * t))
    # Bearings and air: a soft hiss.
    y += circular(rng.standard_normal(n), lambda f: 0.02 * resonance(f, 3500, 0.8))
    return y


def roll(seed, res, grit):
    """A rolling loop, 2 s: shaped noise, and `grit`, sparse little impacts of the
    surface's texture."""
    rng = np.random.default_rng(seed)
    n = 2 * RATE
    x = rng.standard_normal(n)
    if grit:
        g = np.zeros(n)
        k = rng.integers(0, n, int(grit * 2))
        g[k] = rng.uniform(2, 6, len(k)) * rng.choice([-1, 1], len(k))
        x = x + g

    def shape(f):
        s = np.zeros_like(f)
        for fc, q, gain in res:
            s += resonance(f, fc, q, gain)
        return s * (f > 30)
    return circular(x, shape)


def tick(variant):
    """One pawl over one tooth: a click and the hub shell's ring."""
    rng = np.random.default_rng(4000 + variant)
    n = int(0.05 * RATE)
    t = np.arange(n) / RATE
    click = rng.standard_normal(n) * np.exp(-t / 0.0006)
    y = onepole_hp(click, 2500) * 0.6
    for f, a, tau in ((3150, 0.5, 0.006), (4870, 0.35, 0.004), (7420, 0.25, 0.003)):
        f *= 1 + 0.03 * (variant - 2)
        y += a * np.exp(-t / tau) * np.sin(2 * math.pi * f * t + rng.uniform(0, 6.28))
    y *= np.minimum(1, t / 0.0001)
    tail = int(0.01 * RATE)
    y[-tail:] *= np.linspace(1, 0, tail)
    return y


def freewheel():
    """The freewheel at speed, a loop: 60 pawl clicks a second for 1 s. Past about
    25 clicks a second the ear stops hearing ticks and hears a buzz, and one
    EmitSound per click can no longer keep up anyway; cl_sound.lua plays this loop
    there, pitched to the real click rate (100 % = 60 a second)."""
    rng = np.random.default_rng(4100)
    n = RATE
    per = RATE // 60                   # 735 samples: exactly 60 clicks in the loop
    y = np.zeros(n)
    clicks = [tick(1 + (c % 3)) for c in range(3)]
    for c in range(60):
        at = c * per + int(rng.integers(-15, 16))
        k = clicks[c % 3] * (0.8 + 0.4 * rng.random())
        idx = (at + np.arange(len(k))) % n
        np.add.at(y, idx, k)
    return y


def chain():
    """The drivetrain while the cranks turn, a loop: the chain's rollers seating on
    the chainring's teeth (a 25-tooth ring at 120 rpm meshes 50 times a second,
    100 % on this file) and the links rattling over the cog. Quiet: a clean chain
    is mostly a soft whirr."""
    rng = np.random.default_rng(4200)
    n = 2 * RATE
    per = RATE // 50                   # 882 samples: 100 meshes in 2 s
    x = np.zeros(n)
    for c in range(100):
        at = c * per + int(rng.integers(-20, 21))
        x[at % n] += 0.8 + 0.4 * rng.random()
    noise = rng.standard_normal(n) * 0.25
    y = circular(x + noise, lambda f: (resonance(f, 2200, 2.0, 1.0) + resonance(f, 4800, 3.0, 0.6)
                                       + resonance(f, 600, 1.0, 0.15)) * (f > 80))
    return y


def metal_hits(seed, hits, modes, noise_hp=2000):
    """A short metal event: each hit (s, strength) rings `modes` [(f, a, tau)] with a
    click of noise on top. A derailleur shifting, a kickstand, a chain slapping."""
    rng = np.random.default_rng(seed)
    n = int((hits[-1][0] + 0.25) * RATE)
    t = np.arange(n) / RATE
    y = np.zeros(n)
    for when, a0 in hits:
        o = int(when * RATE)
        tt = t[: n - o]
        h = np.zeros(n - o)
        for f, a, tau in modes:
            f *= 1 + rng.uniform(-0.03, 0.03)
            h += a * np.exp(-tt / tau) * np.sin(2 * math.pi * f * tt + rng.uniform(0, 6.28))
        m = int(0.004 * RATE)
        cl = onepole_hp(rng.standard_normal(m) * np.exp(-np.arange(m) / (0.0008 * RATE)), noise_hp)
        h[:m] += cl * 0.8
        y[o:] += a0 * h * np.minimum(1, tt / 0.0002)
    tail = int(0.02 * RATE)
    y[-tail:] *= np.linspace(1, 0, tail)
    return y


CHAIN_MODES = [(2900, 0.5, 0.012), (4600, 0.4, 0.008), (6800, 0.3, 0.006), (1300, 0.2, 0.02)]


def shift(variant):
    # The derailleur moves the chain: a lever click, then the chain clattering onto
    # the next cog over a few teeth, then the clunk as it seats.
    base = [(0.0, 0.5), (0.035, 0.35), (0.05, 0.3), (0.065, 0.3), (0.085, 1.0)]
    return metal_hits(4300 + variant, [(w * (1 + 0.1 * (variant - 1)), a) for w, a in base],
                      CHAIN_MODES + [(820, 0.5, 0.03)])


def chainslap(variant):
    # Landing: the chain whips down onto the chainstay and bounces, a few links at once.
    hits = [[(0.0, 1.0), (0.018, 0.6), (0.05, 0.45), (0.09, 0.25)],
            [(0.0, 1.0), (0.025, 0.5), (0.06, 0.4)],
            [(0.0, 0.9), (0.012, 0.7), (0.04, 0.5), (0.075, 0.3), (0.11, 0.15)]][variant - 1]
    return metal_hits(4400 + variant, hits, CHAIN_MODES)


def kickstand(down):
    # A steel leg on a spring: the snap of the spring, the leg swinging to its stop,
    # and (down) the foot meeting the ground.
    if down:
        hits = [(0.0, 0.5), (0.06, 1.0), (0.075, 0.4)]
    else:
        hits = [(0.0, 0.7), (0.045, 1.0), (0.07, 0.3)]
    return metal_hits(4500 + (1 if down else 0), hits,
                      [(1650, 0.6, 0.05), (3100, 0.4, 0.03), (5200, 0.25, 0.015), (720, 0.3, 0.06)])


def main():
    os.makedirs(OUT, exist_ok=True)
    # The old ring-ring had three; this one has four.
    for v in range(1, 5):
        write(f"bell{v}.wav", bell(v))
    for v in (1, 2):
        write(f"horn{v}.wav", horn(v))
    for v in (1, 2, 3):
        write(f"tick{v}.wav", tick(v))
    write("freewheel.wav", freewheel(), loop=True, level=0.71)
    write("chain.wav", chain(), loop=True, level=0.63)
    for v in (1, 2):
        write(f"shift{v}.wav", shift(v))
    for v in (1, 2, 3):
        write(f"chainslap{v}.wav", chainslap(v))
    write("kickstand_down.wav", kickstand(True))
    write("kickstand_up.wav", kickstand(False))
    write("engine_4t.wav", engine_4t(), loop=True, level=0.71)
    write("engine_2t.wav", engine_2t(), loop=True, level=0.71)
    write("motor.wav", motor(), loop=True, level=0.71)
    write("roll_tyre.wav", roll(5001, [(110, 1.2, 1.0), (420, 1.0, 0.35), (1500, 0.9, 0.06)], 0),
          loop=True, level=0.63)
    write("roll_wheel.wav", roll(5002, [(160, 1.0, 0.6), (900, 0.8, 0.5), (2600, 1.0, 0.25)], 900),
          loop=True, level=0.63)


if __name__ == "__main__":
    sys.exit(main())
