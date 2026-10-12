#!/usr/bin/env python3
"""Diagnostic plot: beads + detected lumens (+ track ids if analysed) for one snapshot.

usage: debug_cells.py RUNDIR --step S [--out f.png] [--zoom x0 y0 w]
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocio  # noqa: E402
import cells as celldet  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rundir")
    ap.add_argument("--step", type=int, default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--zoom", type=float, nargs=3, default=None)
    a = ap.parse_args()
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    snaps = ocio.list_snapshots(a.rundir)
    step, path = snaps[-1] if a.step is None else min(snaps, key=lambda s: abs(s[0] - a.step))
    s = ocio.read_snapshot(path)
    r = celldet.detect(s)
    tracks = {}
    cj = os.path.join(a.rundir, "cells.json")
    if os.path.exists(cj):
        with open(cj) as f:
            d = json.load(f)
        for fr in d["frames"]:
            if fr["step"] == s.step:
                tracks = {c["id"]: c.get("track") for c in fr["cells"]}
    fig, ax = plt.subplots(figsize=(13, 13))
    lab = r["label"].astype(float).T
    lab[lab < 0] = np.nan
    ax.imshow(lab, origin="lower", extent=(0, s.L, 0, s.L), cmap="tab20", alpha=0.45, interpolation="nearest")
    t = s.type
    ba = r["bead_agg"]
    for ty, c, sz in [(3, "#8899cc", 1.5), (1, "#cc5500", 5), (2, "#e8c060", 3), (4, "#119911", 22), (5, "#aacc00", 22), (6, "#cc33aa", 10)]:
        m = t == ty
        ax.scatter(s.x[m], s.y[m], s=sz, c=c, lw=0)
    for c in r["cells"]:
        tid = tracks.get(c["id"])
        ax.text(c["x"], c["y"], f"{c['id']}" + (f"/s{tid}" if tid is not None else "") +
                f"\nA={c['area']:.0f} L={c['n_lipids']}\nK={c['n_Ka']}+{c['n_Kb']} if={c['inner_frac']:.2f}",
                fontsize=8, ha="center", va="center", color="k",
                bbox=dict(fc="white", alpha=0.6, lw=0))
    if a.zoom:
        ax.set_xlim(a.zoom[0], a.zoom[0] + a.zoom[2]); ax.set_ylim(a.zoom[1], a.zoom[1] + a.zoom[2])
    else:
        ax.set_xlim(0, s.L); ax.set_ylim(0, s.L)
    ax.set_aspect("equal")
    ax.set_title(f"{os.path.basename(a.rundir)} step {s.step}: {len(r['cells'])} cells, summary {r['summary']}", fontsize=9)
    out = a.out or f"/tmp/debug_{s.step}.png"
    tmp = ocio.tmp_path(out)
    try:
        fig.savefig(tmp, dpi=80, bbox_inches="tight", format=os.path.splitext(out)[1].lstrip(".") or "png")
        ocio._commit(tmp, out)
    except BaseException:
        ocio._discard(tmp)
        raise
    print(out)


if __name__ == "__main__":
    main()
