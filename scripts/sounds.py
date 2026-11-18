#!/usr/bin/env python3
"""Virt's sounds (App/Sounds). Each is short, quiet and mono, saved as 16-bit .caf (the format iOS takes for a
notification sound, 30 seconds at most).

  sounds.py synth OUTDIR             makes the Chime style: clean synthesized bells (no downloads needed)
  sounds.py survey PACKDIR SHOTDIR   lists every sound in the Kenney packs with its length, level, pitch and decay,
                                     and draws spectrograms of the likely bells, chimes, ticks and clicks
  sounds.py pick PACKDIR PICKS OUTDIR  trims and levels the files PICKS (a JSON file) names, into the Bell style

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


def synth(outdir):
    os.makedirs(outdir, exist_ok=True)
    for cue in CUES:
        x = level(synth_cue(cue), PEAK[cue])
        path = os.path.join(outdir, f"virt-chime-{cue}.caf")
        write_caf(path, x)
        print(f"{os.path.basename(path)}: {len(x) / RATE:.2f} s, {os.path.getsize(path) // 1024} KB")


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
    """PICKS: {"bell": {"go": {"file": "pack/Audio/x.ogg", "start": 0, "length": 1.2, "gain": 0}, ...}}"""
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
    elif cmd == "survey":
        survey(sys.argv[2], sys.argv[3])
    elif cmd == "pick":
        pick(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__)
        sys.exit(1)
