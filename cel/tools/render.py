#!/usr/bin/env python3
"""Render images of an Oercel run (SPEC section 8).

usage:
  render.py RUNDIR --kind micro     [--step S] [--cell TRACK] [--out f.png] [--width 2000]
  render.py RUNDIR --kind goodsell  [--step S] [--cell TRACK] [--out f.png] [--width 2000]
  render.py RUNDIR --kind timelapse [--cell PARENT_TRACK] [--out f.png] [--panels 5]

  micro      simulated confocal fluorescence micrograph (whole dish, or zoomed on --cell)
  goodsell   watercolour molecular illustration of one cell (Goodsell style)
  timelapse  strip of 4-6 fluorescence frames following one cell through division

--cell is a TRACK id ('spoor') from lineage.json (run tools/analyze.py first); it is stable over
time, unlike per-snapshot cell indices.  --step picks the nearest snapshot (default: the last;
for goodsell without --step: the most constricted frame before the first division, if any).
Default output: cel/beelden/<run>_<kind>_<...>.png
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocio  # noqa: E402
import style  # noqa: E402

BEELDEN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "beelden")


def load_analysis(rundir):
    cj = os.path.join(rundir, "cells.json"); lj = os.path.join(rundir, "lineage.json")
    if os.path.exists(cj) and os.path.exists(lj):
        with open(cj) as f:
            cells = json.load(f)
        with open(lj) as f:
            lin = json.load(f)
        return cells, lin
    return None, None


def nearest_snapshot(rundir, step=None):
    snaps = [s for s in ocio.list_snapshots(rundir) if ocio.snapshot_is_complete(s[1])]
    if not snaps:
        raise SystemExit(f"geen snapshots in {rundir}")
    if step is None:
        return snaps[-1]
    return min(snaps, key=lambda s: abs(s[0] - step))


def label_grid(rundir, snap):
    """Lumen label grid for a snapshot: from the analysis cache if present, else detect now."""
    gp = os.path.join(rundir, "analysis_cache", f"grid_{snap.step:010d}.npz")
    jp = os.path.join(rundir, "analysis_cache", f"cells_{snap.step:010d}.json")
    if os.path.exists(gp) and os.path.exists(jp):
        with np.load(gp) as z:
            lab = z["label"].astype(np.int32)
        with open(jp) as f:
            d = json.load(f)
        return lab, d["h"], d["cells"]
    import cells as celldet
    r = celldet.detect(snap)
    return r["label"].astype(np.int32), r["h"], r["cells"]


def track_cell(cells_json, track, step=None):
    """(frame, cell) of a track at the snapshot nearest to step (default: last frame)."""
    best = None
    for f in cells_json["frames"]:
        for c in f["cells"]:
            if c.get("track") == track:
                if step is None:
                    best = (f, c)
                elif best is None or abs(f["step"] - step) < abs(best[0]["step"] - step):
                    best = (f, c)
    if best is None:
        raise SystemExit(f"spoor {track} niet gevonden in cells.json")
    return best


def default_out(rundir, kind, suffix):
    os.makedirs(BEELDEN, exist_ok=True)
    return os.path.join(BEELDEN, f"{os.path.basename(os.path.abspath(rundir))}_{kind}_{suffix}.png")


def best_division(lin, cells_json):
    ev = [e for e in lin.get("events", []) if e["kind"] == "deling"]
    if not ev:
        return None
    tracks = {t["id"]: t for t in lin["tracks"]}

    def score(e):
        kids = [tracks[c] for c in e["children"]]
        cat = sum(1 for k in kids if (k["series"]["n_Ka"][0] + k["series"]["n_Kb"][0]) > 0)
        return (e.get("confirmed", False), cat, min(k["n_frames"] for k in kids), tracks[e["parents"][0]]["n_frames"])
    return max(ev, key=score)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rundir")
    ap.add_argument("--kind", required=True, choices=["micro", "goodsell", "timelapse"])
    ap.add_argument("--step", type=int, default=None)
    ap.add_argument("--cell", type=int, default=None, help="track id (spoor) from lineage.json")
    ap.add_argument("--out", default=None)
    ap.add_argument("--width", type=int, default=2000)
    ap.add_argument("--panels", type=int, default=5)
    ap.add_argument("--zoom", type=float, default=None, help="field of view in sim units (micro/goodsell)")
    ap.add_argument("--rc-nm", type=float, default=1.0, help="nm per DPD length unit for scale bars")
    ap.add_argument("--no-legend", action="store_true")
    a = ap.parse_args()
    style.RC_NM = a.rc_nm
    rundir = a.rundir.rstrip("/")
    cells_json, lin = load_analysis(rundir)
    params = ocio.read_params(rundir)
    synth = bool(params.get("synthetic", 0))

    if a.kind == "micro":
        import render_micro as rm
        step, path = nearest_snapshot(rundir, a.step)
        title = None
        view = None
        if a.cell is not None:
            if cells_json is None:
                raise SystemExit("--cell vereist analyse: draai eerst tools/analyze.py")
            f, c = track_cell(cells_json, a.cell, a.step)
            step, path = nearest_snapshot(rundir, f["step"])
            snap = ocio.read_snapshot(path)
            size = a.zoom or max(30.0, 1.5 * (c["extent"] + 10))
            view = rm.cell_view(snap.L, c["x"], c["y"], min(size, snap.L))
            title = f"cel (spoor) {a.cell}"
        else:
            snap = ocio.read_snapshot(path)
            if a.zoom:
                view = rm.cell_view(snap.L, snap.L / 2, snap.L / 2, a.zoom)
        if synth:
            title = (title + " · " if title else "") + "SYNTHETISCHE TESTDATA"
        img, info = rm.render(snap, view, a.width, ss=2, legend=not a.no_legend, title=title)
        out = a.out or default_out(rundir, "micro", f"{snap.step:010d}" + (f"_spoor{a.cell}" if a.cell is not None else ""))
        img.save(out, optimize=True)
        print(f"[render] {out}  ({img.size[0]}x{img.size[1]}, stap {snap.step}, norm {info['norm']})")

    elif a.kind == "goodsell":
        import render_goodsell as rg
        if a.cell is not None:
            if cells_json is None:
                raise SystemExit("--cell vereist analyse: draai eerst tools/analyze.py")
            f, c = track_cell(cells_json, a.cell, a.step)
            step, path = nearest_snapshot(rundir, f["step"])
            track = a.cell
        else:
            c = None; track = None
            if a.step is None and cells_json is not None and lin is not None:
                e = best_division(lin, cells_json)
                if e is not None:
                    par = next(t for t in lin["tracks"] if t["id"] == e["parents"][0])
                    sol = par["series"]["solidity"]
                    j = int(np.argmin(sol[-3:])) + max(0, len(sol) - 3)
                    track = par["id"]
                    f, c = track_cell(cells_json, track, par["series"]["step"][j])
            step, path = nearest_snapshot(rundir, c and f["step"] if c else a.step)
        snap = ocio.read_snapshot(path)
        lab, h, cl = label_grid(rundir, snap)
        if c is None:
            if not cl:
                raise SystemExit(f"geen cel gevonden in stap {snap.step}; kies --step of --cell")
            c = max(cl, key=lambda c: (c["n_Ka"] + c["n_Kb"] > 0, c["area"]))
        size = a.zoom or (1.05 * c["extent"] + 14)
        what = f"spoor {track}" if track is not None else "cel"
        title = f"Oercel – {what}, stap {ocio.fmt_int_nl(snap.step)}"
        sub = (f"{c['n_lipids']} lipiden · {c['n_Ka']} katalysator a · {c['n_Kb']} katalysator b · "
               f"lumen {ocio.fmt_float_nl(c['area'] * style.RC_NM ** 2, 0)} nm²  —  alle moleculen op hun gesimuleerde "
               f"positie, water weggelaten")
        if synth:
            sub = "SYNTHETISCHE TESTDATA  —  " + sub
        img = rg.render(snap, (c["x"], c["y"]), size, width=a.width, label_grid=lab, label_h=h, title=title,
                        subtitle=sub, legend=not a.no_legend)
        out = a.out or default_out(rundir, "goodsell", f"{snap.step:010d}" + (f"_spoor{track}" if track is not None else ""))
        img.save(out, optimize=True)
        print(f"[render] {out}  ({img.size[0]}x{img.size[1]}, stap {snap.step}, cel bij ({c['x']:.1f}, {c['y']:.1f}))")

    else:
        import render_timelapse as rt
        if cells_json is None or lin is None:
            raise SystemExit("timelapse vereist analyse: draai eerst tools/analyze.py")
        if a.cell is not None:
            ev = [e for e in lin["events"] if e["kind"] == "deling" and a.cell in e["parents"]]
            if not ev:
                raise SystemExit(f"spoor {a.cell} deelt niet (geen 'deling'-gebeurtenis in lineage.json)")
            e = ev[0]
        else:
            e = best_division(lin, cells_json)
            if e is None:
                raise SystemExit("geen deling gevonden in lineage.json - geen time-lapse te maken")
        panel = max(320, int(a.width / a.panels))
        img, panels = rt.render(rundir, cells_json, lin, e, panel_px=panel, n_panels=a.panels)
        out = a.out or default_out(rundir, "timelapse", f"spoor{e['parents'][0]}")
        img.save(out, optimize=True)
        print(f"[render] {out}  ({img.size[0]}x{img.size[1]})  panelen: " +
              ", ".join(f"{p['label']}@{p['step']}" for p in panels))


if __name__ == "__main__":
    main()
