#!/usr/bin/env python3
"""Makes Virt's two intro videos (and the lock screen's still) from Tyler's Kling clips.

    python3 scripts/intro_video.py <launch clip.mp4> <unlock clip.mp4>

Writes App/Intro/virt-launch.mp4, App/Intro/virt-unlock.mp4 and App/Intro/VirtLock.png. Needs ffmpeg, numpy and
Pillow, and takes several minutes (the motion smoothing is slow). The source clips aren't kept in the repo (Tyler has
them); re-run this if he makes new ones, then check the times below against the new clips (they're measured from the
Nov 18, 2026 clips).

The launch clip (1080 x 1920, 24 fps, 5.0 s): VIRT holds with a light sweeping across it (0.67 to 1.83 s), the I, R
and T wipe away (2.0 to 2.71 s), the V grows to its final size (2.71 to 3.71 s), then a slow push-in to 5.0 s. Kept:
from 0.55 s (just before the sweep), with a short fade in from the black launch screen; the wipe at normal speed; the
V growing 1.25x faster (Tyler: "a little faster"); and the slow push-in squeezed into an ease-out, so it still ends on
the clip's own last frame. That last frame is the lock screen's V (VirtLock.png is that exact frame, decoded).

The unlock clip (1080 x 1916, 24 fps, 5.0 s): the large V holds until 0.7 s, the camera flies into it, and it's black
from 4.42 s. Padded 2 px top and bottom to 1080 x 1920 (that lines its V up with the launch clip's, measured). It
starts on the lock screen's own frame and blends into the clip over a short hold, then the zoom is speed-ramped
exponentially (1.8x speeding up to 3.6x; Tyler: "exponential so it's not so slow"), and it ends on black. It's drawn
on a taller canvas (1080 x 2400, taller than any iPhone screen) with a gentle extra zoom (1x to 1.25x over its first
0.8 s of zoom, before the V reaches the old frame's top and bottom): its first frame is the lock screen's exactly
(the app scales both by the screen's width, so the extra height is off screen), and as the camera flies in the gold
runs off the real screen edges instead of stopping at the 9:16 clip's edges.

Speeding a 24 fps clip up by uneven amounts skips frames unevenly, which judders. So both clips are first smoothed to
120 fps (ffmpeg's motion interpolation), then sampled at 60 fps along the new timing.

INTRO_CACHE=<folder> keeps the smoothed frames there, so a re-run only redoes the timing (a few seconds).

Both: no audio track, pure black (#000) background (near-black noise is cleared), the Kling watermark painted out,
H.264 at 60 fps.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

W, H = 1080, 1920
SMOOTH_FPS = 120
OUT_FPS = 60
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Intro")

# the launch clip's watermark ("KlingAI 4.0", measured at x 845-1036, y 1850-1887), with margin; nothing else is there
WATERMARK = (800, 1800, 1080, 1920)
# anything this dark is background noise: made pure black
BLACK_BELOW = 6


class Source:
    """A clip smoothed to 120 fps, as RGB frames on disk (BT.709, video range, as the clips are tagged), read as
    needed (the whole clip doesn't fit in memory)."""

    def __init__(self, path, start, end):
        cache = os.environ.get("INTRO_CACHE")
        self.keep = bool(cache)
        self.start = start
        if cache:
            self.dir = os.path.join(cache, f"{os.path.basename(path)}-{start:.2f}-{end:.2f}")
            if os.path.isdir(self.dir) and os.listdir(self.dir):
                self.names = sorted(os.listdir(self.dir))
                self.cache = {}
                return
            os.makedirs(self.dir, exist_ok=True)
        else:
            self.dir = tempfile.mkdtemp(prefix="virt-intro-")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(start), "-to", str(end), "-i", path, "-an", "-vf",
                        f"minterpolate=fps={SMOOTH_FPS}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1,"
                        "scale=in_color_matrix=bt709:in_range=tv,format=rgb24",
                        "-compression_level", "1", os.path.join(self.dir, "f%05d.png")], check=True)
        self.names = sorted(os.listdir(self.dir))
        self.cache = {}

    def __len__(self):
        return len(self.names)

    def frame(self, i):
        if i not in self.cache:
            if len(self.cache) > 4:
                self.cache.pop(next(iter(self.cache)))
            a = np.asarray(Image.open(os.path.join(self.dir, self.names[i])).convert("RGB"))
            if a.shape[0] != H:
                top = (H - a.shape[0]) // 2
                p = np.zeros((H, W, 3), np.uint8)
                p[top:top + a.shape[0]] = a
                a = p
            self.cache[i] = a.astype(np.float32)
        return self.cache[i]

    def at(self, s):
        """The picture at s seconds of the original clip: a blend of the two smoothed frames around it (1/120 s
        apart, so a blend never doubles an edge)."""
        x = min(max((s - self.start) * SMOOTH_FPS, 0), len(self) - 1)
        i = int(math.floor(x))
        f = x - i
        if i + 1 >= len(self) or f < 1e-3:
            return self.frame(i)
        return self.frame(i) * (1 - f) + self.frame(i + 1) * f

    def close(self):
        if not self.keep:
            shutil.rmtree(self.dir, ignore_errors=True)


def clean(a):
    a = a.copy()
    a[a.max(axis=2) < BLACK_BELOW] = 0
    return np.clip(a + 0.5, 0, 255).astype(np.uint8)


def encode(frames, path, height=H):
    # level 4.2 covers 1080 x 1920 at 60 fps; the taller unlock canvas needs 5.1
    level = "4.2" if height <= H else "5.1"
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{height}", "-r", str(OUT_FPS),
           "-i", "-", "-an", "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
           "-c:v", "libx264", "-preset", "veryslow", "-crf", "17", "-profile:v", "high", "-level", level,
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
           "-movflags", "+faststart", path]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    n = 0
    for f in frames:
        p.stdin.write(f.tobytes())
        n += 1
    p.stdin.close()
    if p.wait() != 0:
        sys.exit("ffmpeg failed")
    return n


def last_frame(path):
    """The encoded clip's last frame, decoded the way the clip is tagged."""
    d = tempfile.mkdtemp(prefix="virt-intro-")
    png = os.path.join(d, "last.png")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-sseof", "-0.1", "-i", path, "-vf",
                    "scale=in_color_matrix=bt709:in_range=tv,format=rgb24", "-update", "1", png], check=True)
    a = np.asarray(Image.open(png).convert("RGB"))
    shutil.rmtree(d, ignore_errors=True)
    return a


# The launch clip's timing (seconds in the original clip)
HOLD = (0.55, 2.00)      # the word, with the light sweeping across it (1x)
WIPE = (2.00, 2.71)      # the I, R and T wipe away (1x)
GROW = (2.71, 3.71)      # the V grows (1.25x: "a little faster"), to where it has slowed almost to rest
DRIFT = (3.71, 5.00)     # the slow push-in, squeezed into an ease-out from 5x to rest
GROW_SPEED, DRIFT_SPEED = 1.25, 5.0
FADE_IN = 0.2


def launch_times():
    t_hold = HOLD[1] - HOLD[0]
    t_wipe = WIPE[1] - WIPE[0]
    t_grow = (GROW[1] - GROW[0]) / GROW_SPEED
    t_drift = 2 * (DRIFT[1] - DRIFT[0]) / DRIFT_SPEED
    total = t_hold + t_wipe + t_grow + t_drift
    n = int(round(total * OUT_FPS)) + 1
    for k in range(n):
        u = min(k / OUT_FPS, total)
        if u < t_hold:
            s = HOLD[0] + u
        elif u < t_hold + t_wipe:
            s = WIPE[0] + (u - t_hold)
        elif u < t_hold + t_wipe + t_grow:
            s = GROW[0] + (u - t_hold - t_wipe) * GROW_SPEED
        else:
            v = u - t_hold - t_wipe - t_grow
            s = DRIFT[0] + DRIFT_SPEED * v - DRIFT_SPEED * v * v / (2 * t_drift)
        if k == n - 1:
            s = DRIFT[1]
        yield k, u, s


def launch_frames(src):
    for k, u, s in launch_times():
        a = src.at(s).copy()
        x0, y0, x1, y1 = WATERMARK
        a[y0:y1, x0:x1] = 0
        f = min(1.0, u / FADE_IN)
        a *= f * f * (3 - 2 * f)
        yield clean(a)


# The unlock clip's timing
U_HOLD, U_ZOOM, U_BLACK = 0.58, 0.70, 4.42   # the hold from, the zoom from, black from
V0, V1 = 1.8, 3.6                            # the speed ramp: exponential from 1.8x to 3.6x
U_MIX = 0.12                                 # blend from the lock screen's frame into the clip
U_TAIL = 2                                   # black frames at the end
U_H = 2400                                   # the taller canvas
U_EXTRA, U_EXTRA_BY = 1.25, 0.8              # the extra zoom, reached this many seconds into the zoom


def extra_zoom(v):
    x = min(max(v / U_EXTRA_BY, 0.0), 1.0)
    return 1 + (U_EXTRA - 1) * x * x * (3 - 2 * x)


def onto_canvas(a, z):
    """A 1080 x 1920 frame on the 1080 x 2400 canvas, centered, zoomed by z about the middle."""
    img = Image.fromarray(a)
    # canvas pixel (X, Y) shows frame pixel ((X - 540) / z + 540, (Y - 1200) / z + 960)
    m = (1 / z, 0, W / 2 - (W / 2) / z, 0, 1 / z, H / 2 - (U_H / 2) / z)
    return np.asarray(img.transform((W, U_H), Image.AFFINE, m, resample=Image.BICUBIC, fillcolor=(0, 0, 0)))


def unlock_times():
    a = (V1 - V0) / (U_BLACK - U_ZOOM)         # integral of V0 * e^(a u) from 0 to t_zoom = U_BLACK - U_ZOOM
    t_zoom = math.log(V1 / V0) / a
    t_hold = U_ZOOM - U_HOLD
    total = t_hold + t_zoom
    n = int(round(total * OUT_FPS)) + 1
    for k in range(n):
        u = k / OUT_FPS
        v = min(max(u - t_hold, 0.0), t_zoom)
        if u < t_hold:
            s = U_HOLD + u
        else:
            s = U_ZOOM + V0 * (math.exp(a * v) - 1) / a
        yield k, u, s, v


def unlock_frames(src, still):
    still = still.astype(np.float32)
    for k, u, s, v in unlock_times():
        a = src.at(s)
        mix = min(1.0, u / U_MIX)
        yield onto_canvas(clean(still * (1 - mix) + a * mix), extra_zoom(v))
    for _ in range(U_TAIL):
        yield np.zeros((U_H, W, 3), np.uint8)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    os.makedirs(OUT, exist_ok=True)

    src = Source(sys.argv[1], HOLD[0] - 0.1, 5.1)
    launch = os.path.join(OUT, "virt-launch.mp4")
    n = encode(launch_frames(src), launch)
    src.close()
    still = last_frame(launch)
    Image.fromarray(still).save(os.path.join(OUT, "VirtLock.png"), optimize=True)
    print(f"launch: {n} frames, {n / OUT_FPS:.2f} s, {os.path.getsize(launch) / 1e6:.2f} MB")

    src = Source(sys.argv[2], U_HOLD - 0.1, U_BLACK + 0.2)
    unlock = os.path.join(OUT, "virt-unlock.mp4")
    n = encode(unlock_frames(src, still), unlock, U_H)
    src.close()
    print(f"unlock: {n} frames, {n / OUT_FPS:.2f} s, {os.path.getsize(unlock) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
