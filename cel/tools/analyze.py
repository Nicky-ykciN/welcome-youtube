#!/usr/bin/env python3
"""Analyse an Oercel run directory (SPEC section 7).

usage: analyze.py RUNDIR [--jobs 2] [--every 1] [--no-cache] [--quiet] [--ram-gb G]

Writes into RUNDIR:
  cells.json       per snapshot: every detected cell (lumen enclosed by one membrane)
  lineage.json     tracks (cell identities over time), divisions/fusions/deaths, lineage tree
  checklist.md     life checklist (SPEC table) with numbers and proving snapshot steps
  checklist.json   same, machine readable
Per-snapshot detection results are cached in RUNDIR/analysis_cache/ so re-running on a growing
run only processes new snapshots.

Robustness for big runs (L up to 2048, thousands of snapshots):
  * every output (and every cache file) is written to a temporary file and renamed: a kill never
    leaves a truncated file; leftovers of killed runs are removed at the next start;
  * --jobs is capped so that the estimated memory of all worker processes fits in the free RAM
    (MemAvailable, or --ram-gb): about 1 GB per process at L = 1024 and 3.6 GB at L = 2048
    (worst case: a box-spanning sponge network; a box of vesicles needs ~40 % of that);
  * the linking phase (overlaps between snapshots, new lipids, event attribution) runs in
    parallel over blocks of consecutive snapshots, and attributes events with a distance
    transform in small windows around the events instead of over the whole box.
"""
import argparse
import gc
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

TOOLS_VERSION = "7"     # results of this version are identical to the former one (cache stays valid)
CACHE = "analysis_cache"
OUT_PREFIXES = ("cells.", "lineage.", "checklist.")
CACHE_PREFIXES = ("cells_", "grid_")


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


# ----------------------------------------------------------------------------- memory budget
mem_available = ocio.mem_available
cap_jobs = ocio.cap_jobs


def detect_mem_estimate(n_beads, L, h=0.25):
    """Peak memory of one detection process (bytes), for the WORST case seen: one membrane
    network spanning the whole box (sponge phase).  Measured with 1 thread on tiled real snapshots:
    vesicles (memA_F2) L = 2048: 1.44 GB; sponge network (memA_n05, 25 % lipid beads, one wrapping
    aggregate of 414 k lipids) L = 1000: 0.73 GB, L = 2000: 2.67 GB.  The estimate below covers
    the sponge case with ~25 % margin (L = 1024: 0.97 GB, L = 2048: 3.6 GB); the former estimate
    (1.25 x (80 MB + 60 B/bead + 20 B/px), 2.6 GB at L = 2000) was below the sponge peak."""
    ng = int(round(L / h))
    return int(1.25 * (90e6 + 80 * n_beads + 26 * ng * ng))


def links_mem_estimate(n_beads, L, G, h=0.25):
    """Peak memory of one linking process: G + 1 label grids (int16) + bool masks + bead arrays."""
    ng = int(round(L / h))
    return int(1.25 * (80e6 + 2 * (G + 1) * ng * ng + 6 * ng * ng + 16 * n_beads))


# ----------------------------------------------------------------------------- detection
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
    # grid first, then the json that carries the key: a kill in between leaves no valid-looking pair
    ocio.save_npz_atomic(gp, label=r["label"], bead_cell=r["bead_cell"], types=snap.type)
    ocio.write_json_atomic(jp, d, default=np_default)
    return d


def load_grid(rundir, step):
    """(label grid, bead_cell, types) of a snapshot from the cache.  The label grid keeps its
    stored integer type (int16, or int32 for >= 32767 cells); -1 = no lumen."""
    _, gp = cache_paths(rundir, step)
    with np.load(gp) as z:
        lab = z["label"]
        if lab.dtype not in (np.int16, np.int32):
            lab = lab.astype(np.int32)
        return lab, z["bead_cell"].astype(np.int32, copy=False), z["types"]


def run_detection(rundir, cfg, jobs=2, every=1, use_cache=True, quiet=False, ram_gb=None):
    snaps = [s for s in ocio.list_snapshots(rundir) if ocio.snapshot_is_complete(s[1])]
    snaps = snaps[::max(1, every)]
    if not snaps:
        raise SystemExit(f"no complete snapshots in {rundir}")
    cdir = os.path.join(rundir, CACHE)
    os.makedirs(cdir, exist_ok=True)
    ocio.cleanup_stale_tmp(cdir, CACHE_PREFIXES)
    for nm in os.listdir(cdir):                       # leftovers of the former fixed temp names
        if nm.endswith(".npz.tmp.npz") or nm.endswith(".json.tmp"):
            try:
                os.unlink(os.path.join(cdir, nm))
            except OSError:
                pass
    key_base = cfg_hash(cfg)
    tasks = []
    for step, path in snaps:
        st = os.stat(path)
        key = f"{key_base}:{st.st_size}:{st.st_mtime_ns}"
        tasks.append((rundir, step, path, cfg, key, use_cache))
    hdr = ocio.read_header(snaps[-1][1])
    n_big = max(hdr["N"], ocio.read_header(snaps[0][1])["N"])
    per_job = detect_mem_estimate(n_big, hdr["L"], cfg.get("h", 0.25))
    t0 = time.time()
    frames = []
    if jobs > 1 and len(tasks) > 4:
        jobs = cap_jobs(jobs, per_job, "detectie", ram_gb, quiet)
    if jobs > 1 and len(tasks) > 4:
        chunk = 1 if n_big > 500_000 else 2
        with get_context("fork").Pool(jobs) as pool:
            for i, d in enumerate(pool.imap(_detect_one, tasks, chunksize=chunk)):
                frames.append(d)
                if not quiet and (i % 50 == 0 or i == len(tasks) - 1):
                    print(f"  detectie {i + 1}/{len(tasks)}  ({time.time() - t0:.0f} s)", flush=True)
    else:
        for i, t in enumerate(tasks):
            frames.append(_detect_one(t))
            if not quiet and (i % 50 == 0 or i == len(tasks) - 1):
                print(f"  detectie {i + 1}/{len(tasks)}  ({time.time() - t0:.0f} s)", flush=True)
    return frames


# ----------------------------------------------------------------------------- linking
def wrap_dilate_labels(label, rad_px):
    """Nearest-lumen label for pixels within rad_px of a lumen (periodic), whole grid.
    (Kept for reference / small grids; analyze uses near_labels_at, which gives the same answer
    at selected pixels without a full-grid distance transform.)"""
    from scipy import ndimage
    pad = int(np.ceil(rad_px)) + 1
    big = np.pad(label, pad, mode="wrap")
    dist, (ii, jj) = ndimage.distance_transform_edt(big < 0, return_indices=True)
    near = big[ii, jj]
    near[dist > rad_px] = -1
    return near[pad:-pad, pad:-pad]


def near_labels_at(label, gi, gj, rad_px, block=256):
    """wrap_dilate_labels(label, rad_px)[gi, gj], computed with distance transforms in windows
    around blocks of query pixels.  A window reaches ceil(rad_px) + 1 pixels beyond its queries,
    so every lumen pixel within rad_px of a query is inside it; the feature transform resolves
    ties between equally distant lumens the same way as on the full grid (it depends only on
    the relative positions of the candidates - checked on random grids with thousands of ties
    and on real runs)."""
    from scipy import ndimage
    gi = np.asarray(gi, np.int64); gj = np.asarray(gj, np.int64)
    out = np.full(len(gi), -1, np.int64)
    if len(gi) == 0:
        return out
    ng0, ng1 = label.shape
    pad = int(np.ceil(rad_px)) + 1
    key = (gi // block) * (ng1 // block + 2) + (gj // block)
    order = np.argsort(key, kind="stable")
    ks = key[order]
    cuts = np.r_[0, np.nonzero(np.diff(ks))[0] + 1, len(ks)]
    for a, b in zip(cuts[:-1], cuts[1:]):
        sel = order[a:b]
        pi, pj = gi[sel], gj[sel]
        lo_i, lo_j = int(pi.min()) - pad, int(pj.min()) - pad
        wi = np.arange(lo_i, int(pi.max()) + pad + 1) % ng0
        wj = np.arange(lo_j, int(pj.max()) + pad + 1) % ng1
        win = label[np.ix_(wi, wj)]
        bg = win < 0
        if bg.all():
            continue
        dist, (ii, jj) = ndimage.distance_transform_edt(bg, return_indices=True)
        qi, qj = pi - lo_i, pj - lo_j
        d = dist[qi, qj]
        v = win[ii[qi, qj], jj[qi, qj]].astype(np.int64)
        v[d > rad_px] = -1
        out[sel] = v
    return out


def _links_block(args):
    """Linking work for the consecutive snapshots k0 .. k1-1 (one worker task).

    Loads the cached label grids of k0-G .. k1-1 one after the other (G = max_gap + 1) and
    returns per snapshot k: lumen pixel areas, raw lumen overlaps with snapshots k-1 .. k-G,
    newly synthesised lipid beads, and the cell (label) at the events assigned to snapshot k."""
    rundir, k0, k1, G, info, stable_ids, evs = args
    out = {}
    ring = {}
    prev_types = None
    for k in range(max(0, k0 - G), k1):
        step, nk, h = info[k]
        lab, bead_cell, types = load_grid(rundir, step)
        ring[k] = lab
        if k >= k0:
            r = {}
            # newly synthesised lipid beads since the previous snapshot (indices are global ids)
            r["nl"] = dict(total=0, wall=0, lumen=0, outside=0)
            r["wc"] = r["lc"] = None
            if stable_ids and k > 0 and prev_types is not None and len(prev_types) == len(types):
                new = (prev_types == ocio.N) & ((types == ocio.H) | (types == ocio.T))
                bc = bead_cell[new]
                r["nl"] = dict(total=int(new.sum()), wall=int((bc <= -2).sum()), lumen=int((bc >= 0).sum()),
                               outside=int((bc == -1).sum()))
                if nk:
                    r["wc"] = np.bincount(-bc[bc <= -2] - 2, minlength=nk).tolist()
                    r["lc"] = np.bincount(bc[bc >= 0], minlength=nk).tolist()
            r["area"] = tracking.area_px(lab, nk)
            r["ov"] = {}
            for g in range(1, G + 1):
                j = k - g
                if j in ring:
                    r["ov"][g] = tracking.overlaps(ring[j], lab)
            e = evs.get(k)
            if e is not None:
                ng = lab.shape[0]
                if len(e["near_idx"]):
                    gi = np.floor(e["ex"] / h).astype(np.int64) % ng
                    gj = np.floor(e["ey"] / h).astype(np.int64) % ng
                    r["ev_in"] = lab[gi, gj].astype(np.int64)
                    r["ev_near"] = near_labels_at(lab, gi, gj, 4.5 / h) if nk else lab[gi, gj].astype(np.int64)
                if len(e["syn_idx"]):
                    ii = e["syn_bead"]
                    ok = (ii >= 0) & (ii < len(bead_cell))
                    bc = bead_cell[ii[ok]]
                    memb = bc <= -2                   # lipid bead in a cell membrane
                    r["lip_sel"] = e["syn_idx"][ok][memb]
                    r["lip_cell"] = (-bc[memb] - 2).astype(np.int64)
            out[k] = r
        prev_types = types
        ring.pop(k - G, None)
    return out


def links_and_attribution(rundir, frames, events, tcfg, quiet=False, stable_ids=True, jobs=1, ram_gb=None):
    """Overlap links (gaps 1..max_gap+1) and attribution of events to cells."""
    K = len(frames)
    G = tcfg["max_gap"] + 1
    links = {}
    steps = np.array([f["step"] for f in frames], np.int64)
    attr = {}
    evs = {}
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
        for k in range(K):
            a0, a1 = np.searchsorted(sn, k), np.searchsorted(sn, k, "right")
            sel = order_near[a0:a1]
            sel = sel[np.isfinite(ex[sel]) & np.isfinite(ey[sel]) & (ex[sel] >= 0) & (ey[sel] >= 0)]
            b0, b1 = np.searchsorted(sx, k), np.searchsorted(sx, k, "right")
            ssel = order_next[b0:b1]
            ssel = ssel[kinds[ssel] == "syn"]
            if len(sel) or len(ssel):
                evs[k] = dict(near_idx=sel, ex=ex[sel], ey=ey[sel], syn_idx=ssel, syn_bead=ei[ssel])
    info = {k: (int(frames[k]["step"]), len(frames[k]["cells"]), float(frames[k]["h"])) for k in range(K)}
    # blocks of consecutive snapshots: few enough grid reloads (G per block), enough blocks to share
    bs = max(1, min(32, -(-K // max(1, 4 * jobs))))
    tasks = []
    for k0 in range(0, K, bs):
        k1 = min(K, k0 + bs)
        sub = {k: info[k] for k in range(max(0, k0 - G), k1)}
        tasks.append((rundir, k0, k1, G, sub, stable_ids, {k: evs[k] for k in range(k0, k1) if k in evs}))
    hdr_n = max(int(f["N"]) for f in frames)
    if jobs > 1 and len(tasks) > 1:
        jobs = cap_jobs(min(jobs, len(tasks)), links_mem_estimate(hdr_n, frames[-1]["L"], G, frames[-1]["h"]),
                        "koppelingen", ram_gb, quiet)
    t0 = time.time()
    res = {}
    done = 0

    def collect(out):
        nonlocal done
        res.update(out)
        done += len(out)
        if not quiet and (done == K or done // 100 != (done - len(out)) // 100):
            print(f"  koppelingen {done}/{K}  ({time.time() - t0:.0f} s)", flush=True)

    if jobs > 1 and len(tasks) > 1:
        # the workers are forked from this process, which may hold millions of cell dicts: freeze
        # them out of the garbage collector, otherwise a collection in a worker touches (and so
        # copies) every page of them
        gc.collect()
        gc.freeze()
        try:
            with get_context("fork").Pool(jobs) as pool:
                for out in pool.imap(_links_block, tasks, chunksize=1):
                    collect(out)
        finally:
            gc.unfreeze()
    else:
        for t in tasks:
            collect(_links_block(t))
    for k in range(K):
        r = res[k]
        fk = frames[k]
        for c in fk["cells"]:
            c["new_wall_beads"] = 0; c["new_lumen_beads"] = 0
        if r["wc"] is not None:
            for c in fk["cells"]:
                c["new_wall_beads"] = int(r["wc"][c["id"]]); c["new_lumen_beads"] = int(r["lc"][c["id"]])
        fk["new_lipid_beads"] = r["nl"]
        fk["_area_px"] = r["area"]
        for g in range(1, G + 1):
            j = k - g
            if j < 0 or g not in r["ov"]:
                continue
            lk = tracking.make_links(r["ov"][g], frames[j]["_area_px"], r["area"], tcfg)
            if g == 1:
                lk += tracking.distance_links(frames[j]["cells"], fk["cells"], lk, fk["L"], tcfg)
            if lk:
                links[(j, g)] = lk
        if len(events) and k in evs:
            e = evs[k]
            if "ev_in" in r:
                ev_in[e["near_idx"]] = r["ev_in"]
                ev_near[e["near_idx"]] = r["ev_near"]
            if "lip_sel" in r:
                ev_lipcell[r["lip_sel"]] = r["lip_cell"]
                fk["_has_beadcell"] = True
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
    ap.add_argument("--jobs", type=int, default=2,
                    help="worker processes for detection and linking (default 2; capped to the free RAM)")
    ap.add_argument("--ram-gb", type=float, default=None,
                    help="memory budget for the worker processes (default: what the system reports free)")
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
    ocio.cleanup_stale_tmp(rundir, OUT_PREFIXES)
    frames = run_detection(rundir, cfg, a.jobs, a.every, not a.no_cache, a.quiet, a.ram_gb)
    n_obs = sum(len(f["cells"]) for f in frames)
    avail = a.ram_gb * 1e9 if a.ram_gb else mem_available()
    if avail and 2200 * n_obs > 0.6 * avail:     # ~2 KB per cell observation in this process
        print(f"[analyze] LET OP: {n_obs} celwaarnemingen in {len(frames)} snapshots vragen ~"
              f"{2200 * n_obs / 1e9:.1f} GB geheugen ({avail / 1e9:.1f} GB vrij); overweeg --every 2", flush=True)
    events = ocio.read_events(rundir, kinds=("syn", "rep", "mut", "dK", "dlip"))
    stable = int(params.get("stable_ids", 1)) != 0   # engine snapshots are in global-id order
    links, attr = links_and_attribution(rundir, frames, events, tcfg, a.quiet, stable, a.jobs, a.ram_gb)
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
    ocio.write_json_atomic(os.path.join(rundir, "cells.json"), cells_out, separators=(",", ":"), default=np_default)
    lineage = dict(run=os.path.basename(rundir), tracks=tracks, events=tr.events,
                   event_attribution=ev_summary,
                   roots=[t["id"] for t in tracks if not t["parents"]],
                   max_generation=max([t["generation"] or 0 for t in tracks], default=0))
    ocio.write_json_atomic(os.path.join(rundir, "lineage.json"), lineage, separators=(",", ":"), default=np_default)

    import checklist
    res = checklist.evaluate(rundir, params, frames, tracks, tr.events, events, ev_summary, tcfg)
    ocio.write_json_atomic(os.path.join(rundir, "checklist.json"), res, indent=1, ensure_ascii=False,
                           default=np_default)
    ocio.write_atomic(os.path.join(rundir, "checklist.md"), checklist.to_markdown(res))
    if not a.quiet:
        print(f"[analyze] {len(frames)} snapshots, {sum(len(f['cells']) for f in frames)} cel-waarnemingen, "
              f"{len(tracks)} sporen, {sum(1 for e in tr.events if e['kind'] == 'deling')} delingen "
              f"({time.time() - t0:.1f} s)")
        for c in res["criteria"]:
            print(f"  {c['id']}. {c['naam']:<22s} {c['status']:<8s} {c['samenvatting']}")


if __name__ == "__main__":
    main()
