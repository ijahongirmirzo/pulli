#!/usr/bin/env python3
"""Renders Pulli's sound cues to WAV files (docs/DECISIONS.md, D-018).

The recipes are the ones on the design canvas's Sound board (synthesised there with Web Audio),
plus the first-launch intro. Pure Python, no dependencies, deterministic output:

    scripts/render-sounds.py [output folder]   (default: Sources/Pulli/Resources/Sounds)
"""
import math, os, random, struct, sys, wave

RATE = 44_100
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Sources", "Pulli", "Resources", "Sounds")


def buffer(seconds):
    return [0.0] * int(RATE * seconds)


def envelope_value(t, start, dur, level):
    """Exponential attack over 12 ms to `level`, then exponential decay to silence at `dur`."""
    local = t - start
    if local < 0 or local > dur:
        return 0.0
    attack = 0.012
    floor = 0.0001
    if local < attack:
        return floor * (level / floor) ** (local / attack)
    return level * (floor / level) ** ((local - attack) / max(dur - attack, 1e-6))


def osc(kind, phase):
    if kind == "triangle":
        x = (phase / (2 * math.pi)) % 1.0
        return 4 * abs(x - 0.5) - 1
    return math.sin(phase)


def tone(buf, freq, start, dur, level, kind="sine"):
    """A note with two soft overtones, like the canvas recipe."""
    for mult, gain in ((1, level), (2.005, level * 0.18), (3.01, level * 0.05)):
        f = freq * mult
        first = int(start * RATE)
        last = min(len(buf), int((start + dur + 0.05) * RATE))
        for i in range(first, last):
            t = i / RATE
            buf[i] += osc(kind, 2 * math.pi * f * (t - start)) * envelope_value(t, start, dur, gain)


def swell(buf, start, dur, low=350, high=2600, level=0.35, seed=7):
    """Band-passed noise sweeping upwards: an airy 'whoosh'."""
    rng = random.Random(seed)
    first = int(start * RATE)
    count = min(len(buf) - first, int(dur * RATE))
    x1 = x2 = y1 = y2 = 0.0
    q = 1.2
    b0 = b2 = a1 = a2 = 0.0
    for n in range(count):
        if n % 32 == 0:
            f = low * (high / low) ** (n / count)
            w = 2 * math.pi * f / RATE
            alpha = math.sin(w) / (2 * q)
            a0 = 1 + alpha
            b0, b2 = alpha / a0, -alpha / a0
            a1, a2 = -2 * math.cos(w) / a0, (1 - alpha) / a0
        x = rng.uniform(-1, 1)
        y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x
        y2, y1 = y1, y
        p = n / count
        # Rise to the peak at 60 %, then fall away.
        env = (p / 0.6) ** 2 if p < 0.6 else ((1 - p) / 0.4) ** 1.5
        buf[first + n] += y * env * level * 3


def reverb(dry, wet=0.2, room=0.78, spread=23):
    """A small Schroeder room so the cues sound like glass in a space, not raw oscillators."""
    def channel(offset):
        combs = [1116 + offset, 1188 + offset, 1277 + offset, 1356 + offset]
        out = [0.0] * len(dry)
        for delay in combs:
            line = [0.0] * delay
            store = 0.0
            index = 0
            for i, x in enumerate(dry):
                y = line[index]
                store = y * 0.8 + store * 0.2
                line[index] = x + store * room
                index = (index + 1) % delay
                out[i] += y * 0.25
        for delay in (556 + offset, 441 + offset):
            line = [0.0] * delay
            index = 0
            for i in range(len(out)):
                buffered = line[index]
                line[index] = out[i] + buffered * 0.5
                out[i] = buffered - out[i]
                index = (index + 1) % delay
        return [d * (1 - wet) + w * wet for d, w in zip(dry, out)]
    return channel(0), channel(spread)


def write(name, buf, tail=0.0, wet=0.2):
    buf = buf + [0.0] * int(RATE * tail)
    left, right = reverb(buf, wet=wet)
    peak = max(max(abs(v) for v in left), max(abs(v) for v in right), 1e-9)
    gain = 0.5 / peak                                   # peak at -6 dBFS; the app sets the volume
    fade = int(RATE * 0.02)
    frames = bytearray()
    for i, (l, r) in enumerate(zip(left, right)):
        k = min(1.0, (len(left) - i) / fade)
        frames += struct.pack("<hh", int(max(-1, min(1, l * gain * k)) * 32767), int(max(-1, min(1, r * gain * k)) * 32767))
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, f"{name}.wav"), "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(bytes(frames))
    print(f"{name}.wav  {len(left) / RATE:.2f} s")


# The six cues from the canvas.
b = buffer(1.0); tone(b, 784, 0, 0.45, 0.5); tone(b, 1175, 0.09, 0.6, 0.45); write("connect", b, 0.4)
b = buffer(1.0); swell(b, 0, 0.42); tone(b, 392, 0.28, 0.5, 0.3); write("start", b, 0.4)
b = buffer(1.0); tone(b, 659, 0, 0.5, 0.35); tone(b, 494, 0.14, 0.7, 0.32); write("pause", b, 0.4)
b = buffer(0.7); tone(b, 494, 0, 0.3, 0.3); tone(b, 740, 0.08, 0.45, 0.34); write("resume", b, 0.4)
# "Get Started": a short airy lift into two rising notes, off into the app.
b = buffer(1.0); swell(b, 0, 0.3, low=900, high=4200, level=0.22, seed=21); tone(b, 880, 0.1, 0.4, 0.36); tone(b, 1319, 0.19, 0.6, 0.38); write("begin", b, 0.4)
b = buffer(1.9)
for freq, start, dur, level in ((523, 0, 0.9, 0.36), (659, 0.08, 0.9, 0.34), (784, 0.16, 1.0, 0.34), (1047, 0.27, 1.5, 0.32)):
    tone(b, freq, start, dur, level)
tone(b, 2093, 0.42, 1.2, 0.05, "triangle")
write("done", b, 0.5, wet=0.25)
b = buffer(0.5); tone(b, 330, 0, 0.12, 0.45, "triangle"); tone(b, 330, 0.15, 0.12, 0.4, "triangle"); write("attention", b, 0.3)

# First-launch intro (about 4 s), timed to the animation in IntroView: an airy rise while the
# logo gathers (0-1.1 s), a warm low note as it lands, then a rising glass arpeggio that blooms
# into a chord with a shimmer as the name appears.
b = buffer(4.2)
swell(b, 0.0, 1.2, low=200, high=3200, level=0.3, seed=11)
tone(b, 131, 1.05, 2.6, 0.30)                  # C3, warm floor
tone(b, 262, 1.05, 2.2, 0.16)
for index, freq in enumerate((523, 659, 784, 988, 1175)):   # C5 E5 G5 B5 D6
    tone(b, freq, 1.1 + index * 0.09, 2.2 - index * 0.15, 0.26 - index * 0.025)
tone(b, 2093, 1.55, 1.8, 0.05, "triangle")
tone(b, 3136, 1.7, 1.4, 0.025, "triangle")
swell(b, 2.9, 0.9, low=1800, high=5000, level=0.06, seed=12)  # a faint sparkle at "Get started"
write("intro", b, 0.6, wet=0.32)
