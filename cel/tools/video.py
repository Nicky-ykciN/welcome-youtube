#!/usr/bin/env python3
"""MP4 time-lapse of the whole dish (SPEC 8.4) in the fluorescence-micrograph style.

usage: video.py RUNDIR --out film.mp4 [--fps 12] [--width 1080] [--every 1] [--jobs 2]
                [--interp 0] [--hold 1.5] [--start S] [--stop S]

Frames are rendered in parallel (--jobs processes) and piped as raw RGB into ffmpeg (H.264,
yuv420p, crf 18).  One fixed normalisation ('exposure') is used for the whole film, measured
on a few sample snapshots, so brightness does not flicker.  Camera noise is re-drawn per frame
(like a real detector) but each molecule keeps its dye brightness.  --interp k inserts k
cross-faded frames between snapshots (smoother when snapshots are sparse).
"""
import argparse
import os
import subprocess
import sys
import time
from multiprocessing import get_context

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocio  # noqa: E402
import render_micro as rm  # noqa: E402
import style  # noqa: E402

_G = {}


def _init(norm, width, synth, total):
    _G.update(norm=norm, width=width, synth=synth, total=total)


def _frame(args):
    k, path = args
    snap = ocio.read_snapshot(path)
    title = "SYNTHETISCHE TESTDATA" if _G["synth"] else None
    img, _ = rm.render(snap, None, _G["width"], ss=1, norm=_G["norm"], seed=1000 + k, title=title)
    return np.asarray(img, dtype=np.uint8)


def calibrate(paths, width, n=5):
    norms = []
    for p in [paths[int(i)] for i in np.linspace(0, len(paths) - 1, min(n, len(paths)))]:
        snap = ocio.read_snapshot(p)
        ch = rm.channel_images(snap, rm.full_view(snap.L), width // 2, width // 2, dict(rm.DEFAULT), 1)
        norms.append(rm.auto_norm(ch).get("memb", 1.0))
    return {"memb": float(np.median(norms))}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rundir")
    ap.add_argument("--out", required=True)
    ap.add_argument("--fps", type=float, default=12)
    ap.add_argument("--width", type=int, default=1080)
    ap.add_argument("--every", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--interp", type=int, default=0)
    ap.add_argument("--hold", type=float, default=1.5, help="seconds to hold the last frame")
    ap.add_argument("--start", type=int, default=None)
    ap.add_argument("--stop", type=int, default=None)
    ap.add_argument("--rc-nm", type=float, default=1.0)
    a = ap.parse_args()
    style.RC_NM = a.rc_nm
    width = a.width - a.width % 2
    snaps = [s for s in ocio.list_snapshots(a.rundir) if ocio.snapshot_is_complete(s[1])]
    if a.start is not None:
        snaps = [s for s in snaps if s[0] >= a.start]
    if a.stop is not None:
        snaps = [s for s in snaps if s[0] <= a.stop]
    snaps = snaps[::max(1, a.every)]
    if not snaps:
        raise SystemExit("geen snapshots")
    paths = [p for _, p in snaps]
    synth = bool(ocio.read_params(a.rundir).get("synthetic", 0))
    norm = calibrate(paths, width)
    print(f"[video] {len(paths)} snapshots, {width}x{width}, fps {a.fps}, norm {norm}", flush=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{width}x{width}", "-r", str(a.fps), "-i", "-",
           "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
           "-movflags", "+faststart", a.out]
    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    t0 = time.time()
    prev = None
    nframes = 0
    with get_context("fork").Pool(max(1, a.jobs), initializer=_init, initargs=(norm, width, synth, len(paths))) as pool:
        for i, fr in enumerate(pool.imap(_frame, list(enumerate(paths)), chunksize=1)):
            if prev is not None and a.interp > 0:
                for j in range(1, a.interp + 1):
                    w = j / (a.interp + 1)
                    mix = (prev.astype(np.float32) * (1 - w) + fr.astype(np.float32) * w + 0.5).astype(np.uint8)
                    ff.stdin.write(mix.tobytes()); nframes += 1
            ff.stdin.write(fr.tobytes()); nframes += 1
            prev = fr
            if i % 25 == 0 or i == len(paths) - 1:
                print(f"  frame {i + 1}/{len(paths)}  ({time.time() - t0:.0f} s)", flush=True)
    for _ in range(int(round(a.hold * a.fps))):
        ff.stdin.write(prev.tobytes()); nframes += 1
    ff.stdin.close()
    rc = ff.wait()
    if rc != 0:
        raise SystemExit(f"ffmpeg faalde (code {rc})")
    print(f"[video] {a.out}: {nframes} frames, {nframes / a.fps:.1f} s ({time.time() - t0:.0f} s rekentijd)")


if __name__ == "__main__":
    main()
