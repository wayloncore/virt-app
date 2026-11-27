#!/usr/bin/env python3
"""Virt's sounds (App/Sounds). Each is short, quiet and mono, saved as 16-bit .caf (the format iOS takes for a
notification sound, 30 seconds at most).

  sounds.py synth OUTDIR             makes the Chime style: clean synthesized bells (no downloads needed)
  sounds.py start OUTDIR             makes only the green light (virt-start-go.caf), the sound when a rest ends
  sounds.py tones OUTDIR             makes the zero tones: Digital's rising trill and one tone for each of the newer
                                     styles (Arcade to Quest jingle), loud and clear
  sounds.py survey PACKDIR SHOTDIR   lists every sound in the Kenney packs with its length, level, pitch and decay,
                                     and draws spectrograms of the likely bells, chimes, ticks and clicks
  sounds.py pick PACKDIR PICKS OUTDIR  trims and levels the files PICKS (a JSON file) names, into the Digital style

The Kenney packs are CC0 (App/Sounds/LICENSES.md). The workflow .github/workflows/sounds.yml downloads them on a
GitHub runner (this repo never keeps the packs, only the few files picked from them).

Needs numpy; `survey` and `pick` also need soundfile (to read .ogg) and Pillow (for the spectrograms).
"""
import json, os, struct, sys

import numpy as np

RATE = 44100
CUES = ["tick", "go", "rest", "set", "finish"]
# peak levels, in dBFS: the zero sounds clear but not loud, the ticks and the click well under them
PEAK = {"tick": -20.0, "go": -7.0, "rest": -7.0, "set": -22.0, "finish": -9.0}


# ---------- files ----------

def write_caf(path, samples):
    """16-bit little-endian linear PCM, mono, in a Core Audio Format file."""
    pcm = np.clip(np.round(samples * 32767), -32768, 32767).astype("<i2").tobytes()
    desc = struct.pack(">dIIIIII", float(RATE), int.from_bytes(b"lpcm", "big"), 2, 2, 1, 1, 16)
    # 2 = kCAFLinearPCMFormatFlagIsLittleEndian; bytes per packet, frames per packet, channels, bits per channel
    with open(path, "wb") as f:
        f.write(b"caff" + struct.pack(">HH", 1, 0))
        f.write(b"desc" + struct.pack(">q", len(desc)) + desc)
        data = struct.pack(">I", 0) + pcm  # edit count, then the samples
        f.write(b"data" + struct.pack(">q", len(data)) + data)


def read_any(path):
    """Any audio file (.ogg, .wav) as mono float samples at RATE (soundfile, with plain resampling if needed)."""
    import soundfile
    x, rate = soundfile.read(path, dtype="float64", always_2d=True)
    x = x.mean(axis=1)
    if rate != RATE and len(x) > 1:
        n = int(round(len(x) * RATE / rate))
        x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)
    return x


def level(x, peak_db):
    """Scales to a peak level, with a short fade at each end so nothing clicks."""
    x = np.asarray(x, dtype=np.float64)
    p = np.max(np.abs(x)) or 1.0
    x = x * (10 ** (peak_db / 20) / p)
    n = min(len(x) // 4, int(0.004 * RATE))
    if n > 1:
        x[:n] *= np.linspace(0, 1, n)
    m = min(len(x) // 4, int(0.03 * RATE))
    if m > 1:
        x[-m:] *= np.linspace(1, 0, m) ** 2
    return np.concatenate([x, np.zeros(int(0.02 * RATE))])


# ---------- the Chime style (synthesized) ----------

def t_axis(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def bell(freq, seconds=1.1, decay=0.42, bright=1.0):
    """A soft struck bell: a few slightly stretched partials, the high ones dying first, with a 3 ms attack so it
    starts clean (no click)."""
    t = t_axis(seconds)
    partials = [(1.0, 1.0, 1.0), (2.0, 0.32 * bright, 0.55), (3.01, 0.12 * bright, 0.32), (4.2, 0.05 * bright, 0.2)]
    x = np.zeros_like(t)
    for ratio, amp, life in partials:
        f = freq * ratio
        if f > RATE / 2.4:
            continue
        x += amp * np.sin(2 * np.pi * f * t) * np.exp(-t / (decay * life))
    attack = np.minimum(1, t / 0.003)
    return x * (0.5 - 0.5 * np.cos(np.pi * attack))


def place(parts, seconds):
    out = np.zeros(int(seconds * RATE))
    for start, sig, gain in parts:
        i = int(start * RATE)
        n = min(len(sig), len(out) - i)
        out[i:i + n] += gain * sig[:n]
    return out


A5, CS6, E6, A6, E5, A4 = 880.0, 1108.73, 1318.51, 1760.0, 659.26, 440.0


def synth_cue(cue):
    if cue == "go":  # rest over, back to work: a fifth up
        return place([(0, bell(A5), 0.85), (0.12, bell(E6), 1.0)], 1.3)
    if cue == "rest":  # work over, rest: the same fifth down
        return place([(0, bell(E6), 1.0), (0.12, bell(A5, decay=0.5), 0.85)], 1.35)
    if cue == "tick":  # a soft wooden tick
        t = t_axis(0.06)
        return (np.sin(2 * np.pi * 1200 * t) + 0.25 * np.sin(2 * np.pi * 2650 * t)) * np.exp(-t / 0.012)
    if cue == "set":  # a tiny click
        t = t_axis(0.03)
        rng = np.random.default_rng(7)
        noise = np.convolve(rng.standard_normal(len(t)), np.ones(6) / 6, mode="same")
        return (0.6 * np.sin(2 * np.pi * 2900 * t) + 0.4 * noise) * np.exp(-t / 0.004)
    if cue == "finish":  # warm: a low major arpeggio, then the octave
        return place([(0, bell(A4, 1.6, 0.6, 0.7), 0.8), (0.11, bell(554.37, 1.6, 0.6, 0.7), 0.75),
                      (0.22, bell(E5, 1.6, 0.6, 0.7), 0.75), (0.36, bell(A5, 1.5, 0.55, 0.8), 0.85)], 1.95)
    raise ValueError(cue)


# The green light (Tyler, Nov 24: "a training green-light sound"), like the start of a race: three short even tones,
# then one longer, higher "go" tone an octave up. Pure tones with a soft second partial and gentle edges, so it's
# clean, not harsh. The go tone starts at START_LEAD seconds (VirtCore's SoundStyle.startLead), so the app starts the
# sound that much before the zero and the go lands on it. Under 2 seconds in all.
START_LEAD = 1.2
START_PEAK = -6.0


def tone(freq, seconds, rise=0.008, fall=0.06, second=0.18):
    """A clean tone: the note, a soft octave partial, a 8 ms rise and a smooth fall (no click at either end)."""
    t = t_axis(seconds)
    x = np.sin(2 * np.pi * freq * t) + second * np.sin(2 * np.pi * 2 * freq * t)
    env = np.ones_like(t)
    r, f = int(rise * RATE), int(fall * RATE)
    env[:r] = 0.5 - 0.5 * np.cos(np.pi * np.arange(r) / r)
    env[-f:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(f) / f)
    return x * env


def green_light():
    beep, go = 880.0, 1760.0  # A5 for the three, A6 for go
    parts = [(i * 0.4, tone(beep, 0.13), 0.8) for i in range(3)]
    # the go tone: longer, with a slow fade so it rings out
    t = t_axis(0.6)
    ring = tone(go, 0.6, fall=0.25, second=0.12) * np.exp(-t / 0.9)
    parts.append((START_LEAD, ring, 1.0))
    return place(parts, START_LEAD + 0.62)


def start(outdir):
    os.makedirs(outdir, exist_ok=True)
    x = level(green_light(), START_PEAK)
    path = os.path.join(outdir, "virt-start-go.caf")
    write_caf(path, x)
    print(f"{os.path.basename(path)}: {len(x) / RATE:.2f} s, {os.path.getsize(path) // 1024} KB")


def synth(outdir):
    os.makedirs(outdir, exist_ok=True)
    for cue in CUES:
        x = level(synth_cue(cue), PEAK[cue])
        path = os.path.join(outdir, f"virt-chime-{cue}.caf")
        write_caf(path, x)
        print(f"{os.path.basename(path)}: {len(x) / RATE:.2f} s, {os.path.getsize(path) // 1024} KB")
    start(outdir)


# ---------- the tones (Tyler, Nov 27) ----------
# One loud, clear zero sound per style, synthesized here from plain waves (no samples). Tyler heard these exact sounds
# and approved them ("These are good except the whistle one"), so keep the synthesis as it is. The game-style ones
# (Level up, Coin pickup, Victory, Bounce, Quest jingle) are original little tunes, not copies of any game's jingle;
# keep it that way. Each is leveled to TONE_PEAK, with TONE_TAIL of silence after it.
TONE_PEAK = -1.5
TONE_TAIL = 0.05

NOTE = {"C4": 261.63, "E4": 329.63, "G4": 392.0, "C5": 523.25, "D5": 587.33, "E5": 659.26, "F5": 698.46,
        "G5": 783.99, "A5": 880.0, "B5": 987.77, "C6": 1046.5, "D6": 1174.66, "E6": 1318.51, "F6": 1396.91,
        "G6": 1567.98, "A6": 1760.0, "B6": 1975.53, "C7": 2093.0}


def t_env(x, a=0.005, r=0.05):
    """A straight rise over `a` seconds and a squared fall over the last `r` seconds."""
    n = len(x)
    e = np.ones(n)
    ia, ir = int(a * RATE), int(r * RATE)
    e[:ia] = np.linspace(0, 1, ia)
    e[-ir:] *= np.linspace(1, 0, ir) ** 2
    return x * e


def t_square(f, s, duty=0.5, soft=6):
    """A soft square (or pulse, by `duty`) wave: its first `soft` harmonics, none near the top of the range."""
    t = t_axis(s)
    return sum(np.sin(2 * np.pi * f * k * t) * np.sin(np.pi * k * duty) / k
               for k in range(1, soft + 1) if f * k < RATE / 2.2)


def t_sine(f, s):
    return np.sin(2 * np.pi * f * t_axis(s))


def t_bell(f, s=1.4, d=0.5, parts=((1, 1, 1), (2.0, .35, .55), (3.01, .15, .32), (4.2, .07, .2))):
    """A struck bell: (ratio, amplitude, life) partials, the high ones dying first."""
    t = t_axis(s)
    x = np.zeros_like(t)
    for r, a, life in parts:
        if f * r < RATE / 2.3:
            x += a * np.sin(2 * np.pi * f * r * t) * np.exp(-t / (d * life))
    return t_env(x, 0.003, 0.05)


def t_chip(f, s, duty=0.25):
    """A chip-tune note: a pulse wave with a quick decay."""
    return t_env(t_square(f, s, duty, 7) * np.exp(-t_axis(s) / (s * 1.5)), 0.002, 0.02)


def t_triangle(f, s):
    t = t_axis(s)
    return t_env(sum(((-1) ** k) * np.sin(2 * np.pi * f * (2 * k + 1) * t) / (2 * k + 1) ** 2 for k in range(5)),
                 0.003, 0.03)


def t_seq(notes, fn, tail=0.3):
    """Notes one after another ((name, seconds); None for a gap); the last one rings on for `tail`."""
    parts, t = [], 0.0
    for n, d in notes:
        if n:
            parts.append((t, fn(NOTE[n], d + (tail if (n, d) == notes[-1] else 0.02)), 1))
        t += d
    return place(parts, t + tail)


def tone_digital_up():  # Digital's work-ends sound: a fast trill rising, then a held high note (louder than before)
    E5, G5, B5, E6, G6 = (NOTE[k] for k in ("E5", "G5", "B5", "E6", "G6"))
    run = [(i * 0.07, t_env(t_square(f, 0.09, 0.5, 5), 0.003, 0.02), 1) for i, f in enumerate([E5, G5, B5, E6, G6, B5 * 2])]
    held = t_env(t_square(E6 * 2, 0.35, 0.5, 4) * np.exp(-t_axis(0.35) / 0.18), 0.003, 0.08)
    return place(run + [(0.42, held, 1)], 0.8)


def tone_arcade():  # an 8-bit sweep up, then two notes
    t = t_axis(0.3)
    f = 400 * 2 ** (t / 0.3 * 2)
    sweep = np.sign(np.sin(2 * np.pi * np.cumsum(f) / RATE)) * 0.6
    return place([(0, t_env(sweep, 0.003, 0.02), 1), (0.32, t_env(t_square(NOTE["C6"], 0.1, 0.25), 0.003, 0.02), 1),
                  (0.44, t_env(t_square(NOTE["G6"], 0.3, 0.25) * np.exp(-t_axis(0.3) / 0.2), 0.003, 0.06), 1)], 0.8)


def tone_ring_bell():  # a boxing-ring bell, struck twice
    def strike():
        return t_bell(1250, 1.6, 0.7, ((1, 1, 1), (1.5, .5, .6), (2.76, .45, .5), (5.4, .25, .3), (8.9, .12, .2)))
    return place([(0, strike(), 1), (0.28, strike(), 1)], 1.9)


def tone_marimba():  # warm wooden notes rising to the octave
    def bar(f):
        t = t_axis(0.7)
        return t_env(np.sin(2 * np.pi * f * t) * np.exp(-t / 0.22) + 0.35 * np.sin(2 * np.pi * f * 4 * t) * np.exp(-t / 0.05),
                     0.002, 0.05)
    return place([(0, bar(NOTE["C5"]), 1), (0.13, bar(NOTE["E5"]), 1), (0.26, bar(NOTE["G5"]), 1),
                  (0.42, bar(NOTE["C6"]), 1.1)], 1.15)


def tone_sonar():  # one clear ping, with two echoes
    t = t_axis(0.9)
    ping = t_env(np.sin(2 * np.pi * 1480 * t) * np.exp(-t / 0.25), 0.004, 0.05)
    return place([(0, ping, 1), (0.33, ping, 0.35), (0.66, ping, 0.12)], 1.6)


def tone_buzzer_horn():  # a gym scoreboard's horn
    t = t_axis(0.9)
    return t_env(sum(np.sin(2 * np.pi * f * k * t) / k for f in (233.08, 311.13) for k in range(1, 14)), 0.02, 0.12)


def tone_synth_rise():  # a smooth two-chord swell up
    def pad(fs, s):
        t = t_axis(s)
        return t_env(sum(np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * f * 2.005 * t) for f in fs), 0.03, 0.2)
    A5, E5, C6, E6 = NOTE["A5"], NOTE["E5"], NOTE["C6"], NOTE["E6"]
    return place([(0, pad((A5 / 2, E5), 0.3), 0.8), (0.22, pad((A5, C6 * 1.0595, E6), 0.9) * np.exp(-t_axis(0.9) / 0.5), 1)],
                 1.15)


def tone_glass():  # a bright, high double tap
    return place([(0, t_bell(NOTE["E6"] * 1.5, 1.0, 0.3), 0.9), (0.11, t_bell(NOTE["A6"] * 1.5, 1.2, 0.35), 1)], 1.35)


def tone_watch_beeps():  # a sports watch: two beeps, then a longer higher one
    return place([(0, t_env(t_sine(2000, 0.08)), 1), (0.13, t_env(t_sine(2000, 0.08)), 1),
                  (0.26, t_env(t_sine(2666, 0.3)), 1)], 0.6)


def tone_level_up():  # a quick rising run to a held high note
    return t_seq([("C5", .07), ("E5", .07), ("G5", .07), ("C6", .07), ("E6", .07), ("G6", .07), ("C7", .35)], t_chip)


def tone_coin_pickup():  # a bright blip up
    return t_seq([("B5", .07), ("E6", .07), ("B6", .4)], lambda f, s: t_chip(f, s, 0.5))


def tone_victory():  # a short fanfare over a soft bass line
    tune = t_seq([("G5", .11), ("G5", .11), ("G5", .11), ("C6", .3), (None, .03), ("A5", .11), ("B5", .11), ("C6", .11),
                  ("E6", .45)], t_chip)
    bass = t_seq([("C4", .33), ("E4", .33), ("G4", .36), ("C5", .45)], t_triangle)
    return tune + 0.5 * np.pad(bass, (0, max(0, len(tune) - len(bass))))[:len(tune)]


def tone_bounce():  # three springy boings, the last one higher
    def boing(f0, f1, s):
        t = t_axis(s)
        ph = 2 * np.pi * np.cumsum(f0 * (f1 / f0) ** (t / s)) / RATE
        return t_env(np.sin(ph) + 0.3 * np.sin(2 * ph), 0.003, 0.03)
    return place([(0, boing(300, 600, .12), 1), (0.16, boing(400, 800, .12), 1), (0.32, boing(500, 1500, .3), 1)], 0.7)


def tone_quest_jingle():  # a cheerful music-box ditty
    def box(f, s):
        return t_bell(f, max(s, 0.6), 0.25, ((1, 1, 1), (3.0, .3, .4), (5.4, .12, .2)))
    return t_seq([("E6", .12), ("G6", .12), ("E6", .12), ("C6", .12), ("D6", .12), ("G6", .5)], box, tail=0.5)


# file name -> synthesis. VirtCore's SoundStyle.file names the same files.
TONES = {
    "virt-digital-up.caf": tone_digital_up,
    "virt-arcade-zero.caf": tone_arcade,
    "virt-ring-bell-zero.caf": tone_ring_bell,
    "virt-marimba-zero.caf": tone_marimba,
    "virt-sonar-zero.caf": tone_sonar,
    "virt-buzzer-horn-zero.caf": tone_buzzer_horn,
    "virt-synth-rise-zero.caf": tone_synth_rise,
    "virt-glass-zero.caf": tone_glass,
    "virt-watch-beeps-zero.caf": tone_watch_beeps,
    "virt-level-up-zero.caf": tone_level_up,
    "virt-coin-pickup-zero.caf": tone_coin_pickup,
    "virt-victory-zero.caf": tone_victory,
    "virt-bounce-zero.caf": tone_bounce,
    "virt-quest-jingle-zero.caf": tone_quest_jingle,
}


def tone_samples(make):
    """The tone at TONE_PEAK, starting right away (on the zero), with a short silence after it."""
    x = np.asarray(make(), dtype=np.float64)
    x = x / np.max(np.abs(x)) * 10 ** (TONE_PEAK / 20)
    return np.concatenate([x, np.zeros(int(TONE_TAIL * RATE))])


def tones(outdir):
    os.makedirs(outdir, exist_ok=True)
    for name, make in TONES.items():
        x = tone_samples(make)
        path = os.path.join(outdir, name)
        write_caf(path, x)
        print(f"{name}: {len(x) / RATE:.2f} s, {os.path.getsize(path) // 1024} KB")


# ---------- the Kenney packs ----------

def stats(x):
    peak = np.max(np.abs(x)) or 1e-9
    env = np.abs(x)
    k = int(0.005 * RATE)
    env = np.convolve(env, np.ones(k) / k, mode="same")
    ip = int(np.argmax(env))
    after = np.where(env[ip:] < env[ip] * 10 ** (-30 / 20))[0]
    decay = after[0] / RATE if len(after) else (len(x) - ip) / RATE
    n = 1 << int(np.ceil(np.log2(max(2048, min(len(x), 1 << 16)))))
    seg = np.pad(x[:n], (0, max(0, n - len(x[:n]))))
    spec = np.abs(np.fft.rfft(seg * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    centroid = float(np.sum(freqs * spec) / (np.sum(spec) or 1))
    dom = float(freqs[int(np.argmax(spec[1:])) + 1])
    tonal = float(np.max(spec) / (np.median(spec) or 1e-9))
    return {"len": len(x) / RATE, "peak_db": 20 * np.log10(peak), "rms_db": 20 * np.log10(np.sqrt(np.mean(x ** 2)) or 1e-9),
            "attack_ms": ip / RATE * 1000, "decay30": decay, "centroid": centroid, "dominant": dom, "tonal": tonal}


def audio_files(packdir):
    for root, _, files in os.walk(packdir):
        for f in sorted(files):
            if f.lower().endswith((".ogg", ".wav", ".mp3")):
                yield os.path.join(root, f)


LIKELY = ("bell", "bong", "chime", "glass", "ding", "confirm", "tick", "click", "tone", "pluck", "select", "drop",
          "maximize", "minimize", "question")


def stft_db(x, n=1024, hop=256):
    """A plain spectrogram (dB), 0 to 8 kHz."""
    x = np.pad(x, (0, max(0, n - len(x))))
    frames = 1 + (len(x) - n) // hop
    win = np.hanning(n)
    spec = np.array([np.abs(np.fft.rfft(win * x[i * hop:i * hop + n])) for i in range(frames)]).T
    top = int(8000 / (RATE / n))
    return 20 * np.log10(spec[:top] + 1e-9)


def survey(packdir, shotdir):
    from PIL import Image, ImageDraw

    os.makedirs(shotdir, exist_ok=True)
    rows = []
    for p in audio_files(packdir):
        try:
            x = read_any(p)
        except Exception:
            continue
        if len(x) < 64:
            continue
        s = stats(x)
        rel = os.path.relpath(p, packdir)
        rows.append((rel, s, x))
        print(f"SOUND {rel} | {s['len']:.2f}s peak {s['peak_db']:.1f} rms {s['rms_db']:.1f} attack {s['attack_ms']:.0f}ms "
              f"decay30 {s['decay30']:.2f}s centroid {s['centroid']:.0f} dom {s['dominant']:.0f} tonal {s['tonal']:.0f}")
    likely = [r for r in rows if any(w in os.path.basename(r[0]).lower() for w in LIKELY)]
    # a contact sheet: each sound's spectrogram (0 to 8 kHz up, 0 to 1 s across), 4 across
    w, h, cols = 320, 170, 4
    for i in range(0, len(likely), 24):
        group = likely[i:i + 24]
        sheet = Image.new("RGB", (cols * w, ((len(group) + cols - 1) // cols) * h), (12, 10, 9))
        draw = ImageDraw.Draw(sheet)
        for k, (rel, s, x) in enumerate(group):
            d = stft_db(x[:RATE])
            d = np.clip((d - (d.max() - 70)) / 70, 0, 1)[::-1]
            img = Image.fromarray(np.uint8(np.stack([d * 255, d * 200, d * 130], -1))).resize((w - 10, h - 30))
            ox, oy = (k % cols) * w + 5, (k // cols) * h + 25
            sheet.paste(img, (ox, oy))
            draw.text((ox, oy - 20), f"{rel.split('/')[-1]}  {s['len']:.2f}s", fill=(240, 220, 180))
        sheet.save(os.path.join(shotdir, f"spectro-{i // 24 + 1}.png"))


def pick(packdir, picks_path, outdir):
    """PICKS: {"digital": {"go": {"file": "pack/Audio/x.ogg", "start": 0, "length": 1.2, "gain": 0}, ...}}"""
    picks = json.load(open(picks_path))
    os.makedirs(outdir, exist_ok=True)
    for style, cues in picks.items():
        if style.startswith("_"):
            continue
        for cue, p in cues.items():
            x = read_any(os.path.join(packdir, p["file"]))
            # start at the sound itself (skip leading silence), then the length asked for
            on = np.where(np.abs(x) > np.max(np.abs(x)) * 0.02)[0]
            start = (on[0] if len(on) else 0) + int(p.get("start", 0) * RATE)
            x = x[start:start + int(p.get("length", 30) * RATE)]
            if p.get("then"):  # a second sound after this one (to pair two into one cue)
                y = read_any(os.path.join(packdir, p["then"]["file"]))
                on = np.where(np.abs(y) > np.max(np.abs(y)) * 0.02)[0]
                y = y[(on[0] if len(on) else 0):]
                at = int(p["then"].get("at", 0.12) * RATE)
                z = np.zeros(max(len(x), at + len(y)))
                z[:len(x)] += x
                z[at:at + len(y)] += y * 10 ** (p["then"].get("gain", 0) / 20)
                x = z
            x = level(x, PEAK[cue] + p.get("gain", 0))
            path = os.path.join(outdir, f"virt-{style}-{cue}.caf")
            write_caf(path, x)
            print(f"{os.path.basename(path)} <- {p['file']}: {len(x) / RATE:.2f} s, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "synth":
        synth(sys.argv[2])
    elif cmd == "start":
        start(sys.argv[2])
    elif cmd == "tones":
        tones(sys.argv[2])
    elif cmd == "survey":
        survey(sys.argv[2], sys.argv[3])
    elif cmd == "pick":
        pick(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__)
        sys.exit(1)
