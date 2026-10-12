#!/usr/bin/env python3
"""Self-test of the analysis and image tools (about 1-2 minutes, 2 processes, no GPU needed).

usage: python3 tools/selftest.py [--dir D] [--big]

Uses SYNTHETIC test data (tools/make_synthetic.py: a scripted scene with a division, a dying
cell, a cell on the box corner, ...), never a simulation result.  Checks:
  1. analyze.py finds the scripted division (confirmed, step 80.000) and 5 of 6 checklist rows;
     a second run on the cache gives byte-identical outputs;
  2. kill -9 during analyze.py / render.py: outputs are complete or absent, never truncated, and a
     rerun gives the same outputs;
  3. detection is consistent at a larger box: the last snapshot tiled 2 x 2 (--big: 6 x 6, L = 576)
     gives exactly 4 (36) times the cells with the same areas;
  4. render.py micro (whole dish and --cell), goodsell and timelapse, and video.py give valid
     PNG/MP4 files and leave no temporary files.
Prints PASS/FAIL per check; exit code = number of failures.
"""
import argparse
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ocio  # noqa: E402

FAILS = []


def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg, flush=True)
    if not ok:
        FAILS.append(msg)
    return ok


def tool(*args, quiet=True, check_rc=True):
    env = dict(os.environ, OMP_NUM_THREADS="1")
    r = subprocess.run([sys.executable] + list(args), capture_output=True, text=True, env=env)
    if check_rc and r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
    return r


def outputs(rd):
    out = {}
    for f in ("cells.json", "lineage.json", "checklist.json", "checklist.md"):
        p = os.path.join(rd, f)
        out[f] = open(p, "rb").read() if os.path.exists(p) else None
    return out


def valid_outputs(rd):
    """All final output and cache files parse (temporary *.tmp.* files of a killed run may be
    incomplete - they are never read and are removed by the next run)."""
    def final(paths):
        return [p for p in paths if ".tmp" not in os.path.basename(p)]
    for f in ("cells.json", "lineage.json", "checklist.json"):
        p = os.path.join(rd, f)
        if os.path.exists(p):
            try:
                with open(p) as fh:
                    json.load(fh)
            except ValueError:
                print("      afgekapt:", p)
                return False
    for p in final(glob.glob(os.path.join(rd, "analysis_cache", "cells_*.json"))):
        try:
            with open(p) as fh:
                json.load(fh)
        except ValueError:
            print("      afgekapt:", p)
            return False
    for p in final(glob.glob(os.path.join(rd, "analysis_cache", "grid_*.npz"))):
        try:
            with np.load(p) as z:
                z["label"], z["bead_cell"], z["types"]
        except Exception:
            print("      afgekapt:", p)
            return False
    return True


def tmp_left(d):
    return [n for n in os.listdir(d) if ".tmp" in n]


def kill_after(args, seconds):
    p = subprocess.Popen([sys.executable] + list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env=dict(os.environ, OMP_NUM_THREADS="1"))
    time.sleep(seconds)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait()


def tile(snap, k):
    """k x k periodic copies of a snapshot; bonds across the box edge go to the neighbouring copy."""
    L, n, b = snap.L, snap.n, snap.bonds
    dx = snap.x[b[:, 1]] - snap.x[b[:, 0]]; dy = snap.y[b[:, 1]] - snap.y[b[:, 0]]
    sx = np.where(dx > L / 2, -1, np.where(dx < -L / 2, 1, 0))
    sy = np.where(dy > L / 2, -1, np.where(dy < -L / 2, 1, 0))
    xs, ys, ts, bs = [], [], [], []
    for a in range(k):
        for c in range(k):
            xs.append(snap.x + a * L); ys.append(snap.y + c * L); ts.append(snap.type)
            jc = ((a + sx) % k) * k + (c + sy) % k
            bs.append(np.stack([b[:, 0] + (a * k + c) * n, b[:, 1] + jc * n], 1))
    return ocio.Snapshot(step=snap.step, time=snap.time, L=L * k, x=np.concatenate(xs), y=np.concatenate(ys),
                         type=np.concatenate(ts), bonds=np.concatenate(bs))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=None, help="work directory (default: a temporary one, removed afterwards)")
    ap.add_argument("--big", action="store_true", help="also test a 6 x 6 tiled box (L = 576, ~1 min more)")
    a = ap.parse_args()
    work = a.dir or tempfile.mkdtemp(prefix="oercel_tools_selftest_")
    os.makedirs(work, exist_ok=True)
    rd = os.path.join(work, "synth")
    shutil.rmtree(rd, ignore_errors=True)
    t0 = time.time()
    r = tool(os.path.join(HERE, "make_synthetic.py"), rd)
    if not check(r.returncode == 0, "make_synthetic.py maakt testdata"):
        return 1

    # 1. analysis
    r = tool(os.path.join(HERE, "analyze.py"), rd, "--jobs", "2", "--quiet")
    check(r.returncode == 0 and valid_outputs(rd), "analyze.py draait en schrijft geldige uitvoer")
    lin = json.load(open(os.path.join(rd, "lineage.json")))
    res = json.load(open(os.path.join(rd, "checklist.json")))
    div = [e for e in lin["events"] if e["kind"] == "deling"]
    check(len(div) == 1 and div[0]["step"] == 80000 and div[0]["confirmed"],
          f"de gescripte deling wordt gevonden (bevestigd, stap 80.000): {[(e['step'], e['confirmed']) for e in div]}")
    check(res["n_ja"] == 5 and res["synthetisch"], f"checklist: 5 van 6 'ja' en gemarkeerd als synthetisch ({res['n_ja']})")
    check(any(t["end_reason"] == "verdwenen" for t in lin["tracks"]), "een cel verdwijnt (dood)")
    ref = outputs(rd)
    r = tool(os.path.join(HERE, "analyze.py"), rd, "--jobs", "1", "--quiet")
    check(outputs(rd) == ref, "tweede analyse (uit de cache, 1 proces) geeft byte-identieke uitvoer")
    check(not tmp_left(rd) and not tmp_left(os.path.join(rd, "analysis_cache")), "geen tijdelijke bestanden over")

    # 2. kill -9 robustness
    ok = True
    for i, s in enumerate((0.4, 0.9, 1.5, 2.2, 3.0)):
        kill_after([os.path.join(HERE, "analyze.py"), rd, "--jobs", "2", "--quiet", "--no-cache"], s)
        ok &= valid_outputs(rd)
    check(ok, "kill -9 tijdens analyze.py: uitvoer en cache nooit afgekapt")
    tool(os.path.join(HERE, "analyze.py"), rd, "--jobs", "2", "--quiet")
    check(outputs(rd) == ref and not tmp_left(rd), "na de kills: zelfde uitvoer, tijdelijke resten opgeruimd")
    png = os.path.join(work, "kill.png")
    ok = True
    for s in (0.6, 1.2, 1.8, 2.5):
        kill_after([os.path.join(HERE, "render.py"), rd, "--kind", "micro", "--width", "1400", "--out", png], s)
        if os.path.exists(png):
            try:
                from PIL import Image
                Image.open(png).load()
            except Exception:
                ok = False
    check(ok, "kill -9 tijdens render.py: geen half PNG op de doelnaam")

    # 3. detection at a larger box
    import cells as celldet
    last = ocio.read_snapshot(ocio.list_snapshots(rd)[-1][1])
    base = celldet.detect(last)
    for k in ((2, 6) if a.big else (2,)):
        big = celldet.detect(tile(last, k))
        ab = sorted(c["area"] for c in base["cells"]) * (k * k)
        check(len(big["cells"]) == k * k * len(base["cells"]) and sorted(c["area"] for c in big["cells"]) == sorted(ab),
              f"detectie in een {k}x{k} betegelde doos (L = {last.L * k:g}): {len(big['cells'])} = {k * k} x "
              f"{len(base['cells'])} cellen, zelfde oppervlakken")
        check(big["label"].dtype in (np.int16, np.int32), f"labelrooster {big['label'].dtype}")

    # 4. images
    out = os.path.join(work, "img")
    os.makedirs(out, exist_ok=True)
    track = max(lin["tracks"], key=lambda t: t["n_frames"])["id"]
    jobs = [("micro", ["--kind", "micro", "--width", "1000"]),
            ("micro_cel", ["--kind", "micro", "--cell", str(track), "--width", "800"]),
            ("goodsell", ["--kind", "goodsell", "--cell", str(track), "--width", "800"]),
            ("timelapse", ["--kind", "timelapse", "--width", "1600"])]
    from PIL import Image
    for name, args in jobs:
        p = os.path.join(out, name + ".png")
        r = tool(os.path.join(HERE, "render.py"), rd, *args, "--out", p)
        ok = r.returncode == 0 and os.path.exists(p)
        if ok:
            try:
                Image.open(p).load()
            except Exception:
                ok = False
        check(ok, f"render.py {name}")
    mp4 = os.path.join(out, "film.mp4")
    r = tool(os.path.join(HERE, "video.py"), rd, "--out", mp4, "--width", "360", "--every", "4", "--jobs", "2")
    pr = subprocess.run(["ffprobe", "-v", "error", mp4], capture_output=True) if os.path.exists(mp4) else None
    check(r.returncode == 0 and pr is not None and pr.returncode == 0, "video.py maakt een geldige MP4")
    check(not tmp_left(out), "geen tijdelijke beeld- of filmbestanden over")
    print(f"== {len(FAILS)} fout(en), {time.time() - t0:.0f} s ==")
    if not a.dir:
        shutil.rmtree(work, ignore_errors=True)
    return len(FAILS)


if __name__ == "__main__":
    sys.exit(main())
