#!/usr/bin/env python3
"""Analyse an Oercel run directory (SPEC section 7).

usage: analyze.py RUNDIR [--jobs 2] [--every 1] [--no-cache] [--quiet]

Writes into RUNDIR:
  cells.json       per snapshot: every detected cell (lumen enclosed by one membrane)
  lineage.json     tracks (cell identities over time), divisions/fusions/deaths, lineage tree
  checklist.md     life checklist (SPEC table) with numbers and proving snapshot steps
  checklist.json   same, machine readable
Per-snapshot detection results are cached in RUNDIR/analysis_cache/ so re-running on a growing
run only processes new snapshots.
"""
import argparse
import hashlib
import json
import os
import sys
import time
from multiprocessing import get_context

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocio  # noqa: E402
import cells as celldet  # noqa: E402
import tracking  # noqa: E402

TOOLS_VERSION = "6"
CACHE = "analysis_cache"


def np_default(o):
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return None if not np.isfinite(o) else float(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    raise TypeError(f"not JSON serialisable: {type(o)}")


def cfg_hash(cfg):
    s = json.dumps(cfg, sort_keys=True) + TOOLS_VERSION
    return hashlib.sha1(s.encode()).hexdigest()[:12]


def cache_paths(rundir, step):
    d = os.path.join(rundir, CACHE)
    return os.path.join(d, f"cells_{step:010d}.json"), os.path.join(d, f"grid_{step:010d}.npz")


def _detect_one(args):
    rundir, step, path, cfg, key, use_cache = args
    jp, gp = cache_paths(rundir, step)
    if use_cache and os.path.exists(jp) and os.path.exists(gp):
        try:
            with open(jp) as f:
                d = json.load(f)
            if d.get("key") == key:
                return d
        except (OSError, ValueError):
            pass
    snap = ocio.read_snapshot(path)
    r = celldet.detect(snap, cfg)
    d = dict(key=key, step=snap.step, time=snap.time, L=snap.L, N=int(snap.n),
             h=r["h"], ng=r["ng"], cells=r["cells"], summary=r["summary"],
             counts={nm: int(c) for nm, c in zip(ocio.TYPE_NAMES, np.bincount(snap.type, minlength=7))})
    np.savez_compressed(gp + ".tmp.npz", label=r["label"], bead_cell=r["bead_cell"], types=snap.type)
    os.replace(gp + ".tmp.npz", gp)
    with open(jp + ".tmp", "w") as f:
        json.dump(d, f, default=np_default)
    os.replace(jp + ".tmp", jp)
    return d


def load_grid(rundir, step):
    _, gp = cache_paths(rundir, step)
    with np.load(gp) as z:
        return z["label"].astype(np.int32), z["bead_cell"].astype(np.int32), z["types"]


def run_detection(rundir, cfg, jobs=2, every=1, use_cache=True, quiet=False):
    snaps = [s for s in ocio.list_snapshots(rundir) if ocio.snapshot_is_complete(s[1])]
    snaps = snaps[::max(1, every)]
    if not snaps:
        raise SystemExit(f"no complete snapshots in {rundir}")
    os.makedirs(os.path.join(rundir, CACHE), exist_ok=True)
    key_base = cfg_hash(cfg)
    tasks = []
    for step, path in snaps:
        st = os.stat(path)
        key = f"{key_base}:{st.st_size}:{st.st_mtime_ns}"
        tasks.append((rundir, step, path, cfg, key, use_cache))
    t0 = time.time()
    frames = []
    if jobs > 1 and len(tasks) > 4:
        with get_context("fork").Pool(jobs) as pool:
            for i, d in enumerate(pool.imap(_detect_one, tasks, chunksize=2)):
                frames.append(d)
                if not quiet and (i % 50 == 0 or i == len(tasks) - 1):
                    print(f"  detectie {i + 1}/{len(tasks)}  ({time.time() - t0:.0f} s)", flush=True)
    else:
        for i, t in enumerate(tasks):
            frames.append(_detect_one(t))
            if not quiet and (i % 50 == 0 or i == len(tasks) - 1):
                print(f"  detectie {i + 1}/{len(tasks)}  ({time.time() - t0:.0f} s)", flush=True)
    return frames


def wrap_dilate_labels(label, rad_px):
    """Nearest-lumen label for pixels within rad_px of a lumen (periodic)."""
    from scipy import ndimage
    pad = int(np.ceil(rad_px)) + 1
    big = np.pad(label, pad, mode="wrap")
    dist, (ii, jj) = ndimage.distance_transform_edt(big < 0, return_indices=True)
    near = big[ii, jj]
    near[dist > rad_px] = -1
    return near[pad:-pad, pad:-pad]


def links_and_attribution(rundir, frames, events, tcfg, quiet=False, stable_ids=True):
    """Overlap links (gaps 1..max_gap+1) and attribution of events to cells."""
    K = len(frames)
    G = tcfg["max_gap"] + 1
    links = {}
    steps = np.array([f["step"] for f in frames], np.int64)
    # nearest frame index for each event
    attr = {}
    if len(events):
        es = events["step"].to_numpy()
        idx = np.clip(np.searchsorted(steps, es), 0, K - 1)
        prev = np.clip(idx - 1, 0, K - 1)
        nearest = np.where(np.abs(steps[prev] - es) <= np.abs(steps[idx] - es), prev, idx)
        nxt = idx  # first frame with step >= event step (clipped)
        ev_in = np.full(len(es), -1, np.int64)
        ev_near = np.full(len(es), -1, np.int64)
        ev_lipcell = np.full(len(es), -1, np.int64)
        order_near = np.argsort(nearest, kind="stable")
        order_next = np.argsort(nxt, kind="stable")
        sn = nearest[order_near]; sx = nxt[order_next]
        ex = events["x"].to_numpy(); ey = events["y"].to_numpy(); ei = events["i"].to_numpy()
        kinds = events["kind"].to_numpy()
    ring = {}
    prev_types = None
    t0 = time.time()
    for k in range(K):
        lab, bead_cell, types = load_grid(rundir, frames[k]["step"])
        ring[k] = lab
        nk = len(frames[k]["cells"])
        # newly synthesised lipid beads since the previous snapshot (indices are global ids)
        for c in frames[k]["cells"]:
            c["new_wall_beads"] = 0; c["new_lumen_beads"] = 0
        nl = dict(total=0, wall=0, lumen=0, outside=0)
        if stable_ids and k > 0 and prev_types is not None and len(prev_types) == len(types):
            new = (prev_types == ocio.N) & ((types == ocio.H) | (types == ocio.T))
            bc = bead_cell[new]
            nl = dict(total=int(new.sum()), wall=int((bc <= -2).sum()), lumen=int((bc >= 0).sum()),
                      outside=int((bc == -1).sum()))
            wc = np.bincount(-bc[bc <= -2] - 2, minlength=nk) if nk else []
            lc = np.bincount(bc[bc >= 0], minlength=nk) if nk else []
            for c in frames[k]["cells"]:
                c["new_wall_beads"] = int(wc[c["id"]]); c["new_lumen_beads"] = int(lc[c["id"]])
        frames[k]["new_lipid_beads"] = nl
        prev_types = types
        ring.pop(k - G - 1, None)
        nk = len(frames[k]["cells"])
        ak = tracking.area_px(lab, nk)
        frames[k]["_area_px"] = ak
        for g in range(1, G + 1):
            j = k - g
            if j < 0 or j not in ring:
                continue
            nj = len(frames[j]["cells"])
            ov = tracking.overlaps(ring[j], lab)
            lk = tracking.make_links(ov, frames[j]["_area_px"], ak, tcfg)
            if g == 1:
                lk += tracking.distance_links(frames[j]["cells"], frames[k]["cells"], lk, frames[k]["L"], tcfg)
            if lk:
                links[(j, g)] = lk
        if len(events):
            h = frames[k]["h"]; ng = lab.shape[0]
            a0, a1 = np.searchsorted(sn, k), np.searchsorted(sn, k, "right")
            sel = order_near[a0:a1]
            sel = sel[np.isfinite(ex[sel]) & np.isfinite(ey[sel]) & (ex[sel] >= 0) & (ey[sel] >= 0)]
            if len(sel):
                gi = np.floor(ex[sel] / h).astype(np.int64) % ng
                gj = np.floor(ey[sel] / h).astype(np.int64) % ng
                ev_in[sel] = lab[gi, gj]
                near = wrap_dilate_labels(lab, 4.5 / h) if nk else lab
                ev_near[sel] = near[gi, gj]
            # lipid incorporation: bead i in the next snapshot
            b0, b1 = np.searchsorted(sx, k), np.searchsorted(sx, k, "right")
            sel = order_next[b0:b1]
            sel = sel[kinds[sel] == "syn"]
            if len(sel):
                ii = ei[sel]
                ok = (ii >= 0) & (ii < len(bead_cell))
                bc = bead_cell[ii[ok]]
                memb = bc <= -2                       # lipid bead in a cell membrane
                ev_lipcell[sel[ok][memb]] = -bc[memb] - 2
                frames[k]["_has_beadcell"] = True
        if not quiet and (k % 100 == 0 or k == K - 1):
            print(f"  koppelingen {k + 1}/{K}  ({time.time() - t0:.0f} s)", flush=True)
    if len(events):
        attr = dict(frame=nearest, frame_next=nxt, cell_in=ev_in, cell_near=ev_near, lipcell_next=ev_lipcell)
    return links, attr


def summarise_tracks(frames, tr):
    out = []
    for t in tr.tracks:
        ser = {k: [] for k in ("step", "area", "n_lipids", "n_Ka", "n_Kb", "n_N", "x", "y", "aspect", "solidity", "inner_frac", "agg_lumens", "new_wall_beads")}
        for (k, c) in t["nodes"]:
            cl = frames[k]["cells"][c]
            ser["step"].append(int(frames[k]["step"]))
            for key in ("area", "n_lipids", "n_Ka", "n_Kb", "n_N", "x", "y", "aspect", "solidity", "inner_frac", "agg_lumens", "new_wall_beads"):
                v = cl.get(key, 0)
                ser[key].append(round(v, 2) if isinstance(v, float) else v)
        d = dict(id=t["id"], start_step=ser["step"][0], end_step=ser["step"][-1], n_frames=len(t["nodes"]),
                 start_reason=t["start_reason"], end_reason=t["end_reason"], parents=t["parents"],
                 children=t["children"], generation=t["generation"], fragment=t["fragment"],
                 gaps=t.get("gaps", []), series=ser)
        out.append(d)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rundir")
    ap.add_argument("--jobs", type=int, default=2, help="worker processes for detection (default 2)")
    ap.add_argument("--every", type=int, default=1, help="use every n-th snapshot")
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--min-lumen-area", type=float, default=None)
    ap.add_argument("--r-stamp", type=float, default=None)
    ap.add_argument("--confirm-frames", type=int, default=None)
    a = ap.parse_args()
    rundir = a.rundir.rstrip("/")
    cfg = dict(celldet.DEFAULTS)
    if a.min_lumen_area is not None:
        cfg["min_lumen_area"] = a.min_lumen_area
    if a.r_stamp is not None:
        cfg["r_stamp"] = a.r_stamp
    tcfg = dict(tracking.TRACK_DEFAULTS)
    if a.confirm_frames is not None:
        tcfg["confirm_frames"] = a.confirm_frames
    params = ocio.read_params(rundir)
    if "rho" in params:
        cfg["rho"] = float(params["rho"])
    t0 = time.time()
    if not a.quiet:
        print(f"[analyze] {rundir}")
    frames = run_detection(rundir, cfg, a.jobs, a.every, not a.no_cache, a.quiet)
    events = ocio.read_events(rundir, kinds=("syn", "rep", "mut", "dK", "dlip"))
    stable = int(params.get("stable_ids", 1)) != 0   # engine snapshots are in global-id order
    links, attr = links_and_attribution(rundir, frames, events, tcfg, a.quiet, stable)
    tr = tracking.Tracker(frames, links, tcfg).run()
    # node -> track
    for (k, c), tid in tr.track_of.items():
        frames[k]["cells"][c]["track"] = tid
    tracks = summarise_tracks(frames, tr)

    # event attribution -> tracks
    ev_summary = {}
    if len(events):
        fr = attr["frame"]; ci = attr["cell_in"]; cn = attr["cell_near"]
        tin = np.array([tr.track_of.get((int(f), int(c)), -1) if c >= 0 else -1 for f, c in zip(fr, ci)])
        tnear = np.array([tr.track_of.get((int(f), int(c)), -1) if c >= 0 else -1 for f, c in zip(fr, cn)])
        lipt = np.array([tr.track_of.get((int(f), int(c)), -1) if c >= 0 else -1
                         for f, c in zip(attr["frame_next"], attr["lipcell_next"])])
        events = events.assign(track_in=tin, track_near=tnear, lip_track_next=lipt)
        for t in tracks:
            t["events"] = {}
        kinds = events["kind"].to_numpy(); var = events["variant"].to_numpy()
        for kind in ("syn", "rep", "mut", "dK", "dlip"):
            m = kinds == kind
            col = tnear if kind == "dlip" else tin
            ids, cnt = np.unique(col[m & (col >= 0)], return_counts=True)
            for i, c in zip(ids, cnt):
                tracks[i]["events"][kind] = int(c)
            for v in ("a", "b"):
                mv = m & (var == v) & (col >= 0)
                ids, cnt = np.unique(col[mv], return_counts=True)
                for i, c in zip(ids, cnt):
                    tracks[i]["events"][f"{kind}_{v}"] = int(c)
            ev_summary[kind] = dict(total=int(m.sum()), in_cells=int((m & (tin >= 0)).sum()),
                                    near_cells=int((m & (tnear >= 0)).sum()))
        # incorporation of newly made lipids into the membrane of the same cell
        msyn = (kinds == "syn") & (tin >= 0)
        both = msyn & (lipt >= 0)
        same = both & (lipt == tin)
        # allow incorporation into a daughter if the cell divided before the next snapshot
        kids = {t["id"]: set(t["children"]) for t in tracks}
        fam = np.array([(lipt[j] in kids.get(int(tin[j]), ())) for j in np.nonzero(both & ~same)[0]], bool)
        ev_summary["syn_incorporation"] = dict(
            syn_in_cells=int(msyn.sum()),
            lipid_bead_tracked=int(both.sum()),
            into_same_cell_membrane=int(same.sum() + fam.sum()),
        )
    else:
        for t in tracks:
            t["events"] = {}

    # ----------------------------------------------------------------- write outputs
    detcfg = {k: v for k, v in cfg.items()}
    cells_out = dict(run=os.path.basename(rundir), tools_version=TOOLS_VERSION, detection=detcfg,
                     tracking=tcfg, frames=[])
    for k, f in enumerate(frames):
        cells_out["frames"].append(dict(k=k, step=f["step"], time=f["time"], L=f["L"], N=f["N"],
                                        n_cells=len(f["cells"]), summary=f["summary"], counts=f["counts"],
                                        new_lipid_beads=f.get("new_lipid_beads"), cells=f["cells"]))
    with open(os.path.join(rundir, "cells.json"), "w") as fh:
        json.dump(cells_out, fh, separators=(",", ":"), default=np_default)
    lineage = dict(run=os.path.basename(rundir), tracks=tracks, events=tr.events,
                   event_attribution=ev_summary,
                   roots=[t["id"] for t in tracks if not t["parents"]],
                   max_generation=max([t["generation"] or 0 for t in tracks], default=0))
    with open(os.path.join(rundir, "lineage.json"), "w") as fh:
        json.dump(lineage, fh, separators=(",", ":"), default=np_default)

    import checklist
    res = checklist.evaluate(rundir, params, frames, tracks, tr.events, events, ev_summary, tcfg)
    with open(os.path.join(rundir, "checklist.json"), "w") as fh:
        json.dump(res, fh, indent=1, ensure_ascii=False, default=np_default)
    with open(os.path.join(rundir, "checklist.md"), "w") as fh:
        fh.write(checklist.to_markdown(res))
    if not a.quiet:
        print(f"[analyze] {len(frames)} snapshots, {sum(len(f['cells']) for f in frames)} cel-waarnemingen, "
              f"{len(tracks)} sporen, {sum(1 for e in tr.events if e['kind'] == 'deling')} delingen "
              f"({time.time() - t0:.1f} s)")
        for c in res["criteria"]:
            print(f"  {c['id']}. {c['naam']:<22s} {c['status']:<8s} {c['samenvatting']}")


if __name__ == "__main__":
    main()
