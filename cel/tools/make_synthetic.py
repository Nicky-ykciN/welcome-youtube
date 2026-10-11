#!/usr/bin/env python3
"""Generate a FAKE Oercel run directory (SPEC section 5 formats) for developing the tools.

The scene is hand-scripted, not simulated. It contains, in a periodic water box with nutrients:
  * frame 0: a 'soup' of dispersed lipids; frame 1: micelles and bilayer fragments;
    from frame 2 on closed vesicles (so the tools can detect 'births')
  * cell D: grows, elongates (Cassini oval), constricts and splits into two daughters
    across ~12 frames; one daughter ends up crossing the periodic boundary
  * cell C: sits on the corner of the box (crosses both periodic boundaries)
  * cell X: loses its catalysts, shrinks, its membrane opens and it falls apart (death)
  * cells F1+F2: drift together and fuse
  * cell G: grows steadily; cell S: static, contains Kb
  * free lipids and micelles everywhere
params.ini carries `synthetic = 1` so analysis reports can flag the data as fake.

usage: make_synthetic.py OUTDIR [--frames 24] [--L 96] [--seed 1]
"""
import argparse
import os
import sys

import numpy as np
from matplotlib.path import Path
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocio  # noqa: E402
from ocio import W, H, T, N, KA, KB  # noqa: E402

LIPID_OFFS = np.array([1.75, 1.25, 0.75, 0.25])  # H, T, T, T distance from bilayer midline
SPACING = 0.667                                   # lipid spacing along a leaflet (rho = 3)


# ----------------------------------------------------------------------------- curves
def resample_closed(P, m=1500):
    d = np.r_[0, np.cumsum(np.hypot(*np.diff(np.vstack([P, P[:1]]), axis=0).T))]
    s = np.linspace(0, d[-1], m, endpoint=False)
    Pc = np.vstack([P, P[:1]])
    return np.stack([np.interp(s, d, Pc[:, 0]), np.interp(s, d, Pc[:, 1])], 1)


_WOB = np.random.default_rng(12345)


def circle(cx, cy, r, m=1500, wobble=0.035):
    """Closed CCW curve: circle with small random low-mode shape fluctuations."""
    t = np.linspace(0, 2 * np.pi, m, endpoint=False)
    rr = np.ones_like(t)
    for k in range(2, 7):
        rr += _WOB.normal(0, wobble / k ** 0.8) * np.cos(k * t + _WOB.uniform(0, 2 * np.pi))
    return resample_closed(np.stack([cx + r * rr * np.cos(t), cy + r * rr * np.sin(t)], 1), m)


def cassini(cx, cy, a, c, angle, m=3000):
    """Single-loop Cassini oval (a > c), CCW, rotated by angle."""
    th = np.linspace(0, 2 * np.pi, m, endpoint=False)
    r2 = c * c * np.cos(2 * th) + np.sqrt(np.maximum(a ** 4 - c ** 4 * np.sin(2 * th) ** 2, 0))
    r = np.sqrt(np.maximum(r2, 1e-9))
    x, y = r * np.cos(th), r * np.sin(th)
    ca, sa = np.cos(angle), np.sin(angle)
    P = np.stack([cx + ca * x - sa * y, cy + sa * x + ca * y], 1)
    return resample_closed(P)


def normals(P):
    t = np.roll(P, -1, 0) - np.roll(P, 1, 0)
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    return np.stack([t[:, 1], -t[:, 0]], 1)  # outward for a CCW curve


def bilayer(P, rng, open_frac=0.0, open_at=0.0, jitter=0.055, tilt=0.10, closed=True):
    """Lipids (k,4,2) along a curve P (closed CCW, or open polyline if closed=False)."""
    n = normals(P) if closed else _open_normals(P)
    mols = []
    for sign in (+1, -1):
        Q = P + sign * 1.0 * n
        seg = np.hypot(*np.diff(np.vstack([Q, Q[:1]]) if closed else Q, axis=0).T)
        d = np.r_[0, np.cumsum(seg)]
        total = d[-1]
        k = max(int(round(total / SPACING)), 3)
        s = (np.arange(k) + rng.uniform(0, 1)) * total / k
        idx = np.searchsorted(d, s) % len(P)
        if open_frac > 0:
            u = s / total
            du = np.abs((u - open_at + 0.5) % 1.0 - 0.5)
            keep = du > open_frac / 2
            idx = idx[keep]
        for i in idx:
            nn = n[i]
            a = rng.normal(0, tilt)
            ca, sa = np.cos(a), np.sin(a)
            nr = np.array([ca * nn[0] - sa * nn[1], sa * nn[0] + ca * nn[1]])
            base = P[i] + rng.normal(0, jitter, 2)
            beads = base[None, :] + sign * LIPID_OFFS[:, None] * nr[None, :]
            beads += rng.normal(0, jitter, beads.shape)
            mols.append(beads)
    return mols


def _open_normals(P):
    t = np.gradient(P, axis=0)
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    return np.stack([t[:, 1], -t[:, 0]], 1)


def micelle(cx, cy, k, rng):
    mols = []
    a0 = rng.uniform(0, 2 * np.pi)
    for j in range(k):
        a = a0 + 2 * np.pi * j / k + rng.normal(0, 0.1)
        u = np.array([np.cos(a), np.sin(a)])
        beads = np.array([cx, cy]) + (LIPID_OFFS[:, None] + 0.15) * u[None, :]
        mols.append(beads + rng.normal(0, 0.06, beads.shape))
    return mols


def free_lipid(cx, cy, rng):
    a = rng.uniform(0, 2 * np.pi)
    u = np.array([np.cos(a), np.sin(a)])
    beads = np.array([cx, cy]) + (np.arange(4)[:, None] * 0.5 - 0.75) * u[None, :]
    return [beads + rng.normal(0, 0.06, beads.shape)]


# ----------------------------------------------------------------------------- scene
def scene(f, rng, L):
    """Return list of structures: dict(curve(s), catalysts (na, nb), name)."""
    S = []
    if f < 2:
        return S
    # --- D: grows, elongates, divides (axis 30 deg), right part crosses x = L
    cx, cy, ang = 0.875 * L, 0.42 * L, np.radians(30)
    if f <= 7:
        r = 8.0 + 0.5 * (f - 2)
        S.append(dict(name="D", curves=[circle(cx, cy, r)], na=4 + (f - 2) // 2, nb=1 + (f - 2) // 2))
    elif f <= 15:
        ac = {8: (11.0, 5.0), 9: (11.3, 6.5), 10: (11.6, 7.8), 11: (11.9, 9.0), 12: (12.0, 10.0),
              13: (12.1, 10.9), 14: (12.2, 11.5), 15: (12.25, 11.95)}[f]
        S.append(dict(name="D", curves=[cassini(cx, cy, ac[0], ac[1], ang)], na=7, nb=4 + (f - 8) // 2))
    else:
        sep = 10.6 + 0.8 * (f - 16)
        r = 7.2 + 0.18 * (f - 16)
        u = np.array([np.cos(ang), np.sin(ang)])
        for k, sgn in enumerate((-1, +1)):
            c = np.array([cx, cy]) + sgn * sep * u
            S.append(dict(name=f"D{k + 1}", curves=[circle(c[0], c[1], r)],
                          na=3 + (f - 16) // 4, nb=4 + (f - 16) // 2 if k == 0 else 3 + (f - 16) // 3))
    # --- C: on the corner, slowly growing, Ka only
    S.append(dict(name="C", curves=[circle(1.0, L - 1.0, 7.5 + 0.06 * f)], na=5, nb=0))
    # --- X: loses catalysts, shrinks, opens, falls apart
    if f <= 19:
        r = 9.0 if f <= 11 else 9.0 - 0.28 * (f - 11)
        nka = max(0, 6 - max(0, f - 6) * 2)
        S.append(dict(name="X", curves=[circle(0.30 * L, 0.72 * L, r)], na=nka, nb=0,
                      open_frac=0.0 if f < 18 else 0.22 + 0.1 * (f - 18)))
    # --- F1, F2: approach and fuse
    if f <= 11:
        sep = 17.0 - 0.27 * (f - 2)
        for k, sgn in enumerate((-1, +1)):
            S.append(dict(name=f"F{k + 1}", curves=[circle(0.47 * L + sgn * sep / 2, 0.17 * L, 5.6)],
                          na=2, nb=0))
    else:
        ac = {12: (7.75, 7.3), 13: (8.1, 7.0), 14: (8.6, 6.4), 15: (9.0, 5.5), 16: (9.2, 4.6)}.get(f, (9.35, 3.5))
        S.append(dict(name="F", curves=[cassini(0.47 * L, 0.17 * L, ac[0], ac[1], 0.0)], na=4, nb=0))
    # --- G: grows steadily, Ka + Kb
    S.append(dict(name="G", curves=[circle(0.64 * L, 0.80 * L, 6.0 + 0.16 * f)], na=3, nb=1 + f // 4))
    # --- S: static, mostly Kb
    S.append(dict(name="S", curves=[circle(0.20 * L, 0.30 * L, 7.0)], na=2, nb=3))
    return S


def build_frame(f, L, rng):
    lipids = []        # list of (4,2)
    lumens = []        # (Path, curve, na, nb)
    for s in scene(f, rng, L):
        for P in s["curves"]:
            lipids += bilayer(P, rng, open_frac=s.get("open_frac", 0.0), open_at=0.3)
            lumens.append((P, s["na"], s["nb"], s["name"]))
    # dispersed lipids: soup / micelles / fragments / free
    if f == 0:
        for _ in range(900):
            lipids += free_lipid(*rng.uniform(0, L, 2), rng)
    elif f == 1:
        for _ in range(70):
            lipids += micelle(*rng.uniform(0, L, 2), int(rng.integers(6, 10)), rng)
        for _ in range(10):
            c = rng.uniform(0, L, 2); a = rng.uniform(0, np.pi); ln = rng.uniform(5, 10)
            t = np.linspace(-ln / 2, ln / 2, 200)
            P = c + t[:, None] * np.array([np.cos(a), np.sin(a)])[None, :]
            lipids += bilayer(P, rng, closed=False)
        for _ in range(120):
            lipids += free_lipid(*rng.uniform(0, L, 2), rng)
    else:
        for _ in range(int(rng.integers(10, 16))):
            lipids += micelle(*rng.uniform(0, L, 2), int(rng.integers(6, 9)), rng)
        for _ in range(110):
            lipids += free_lipid(*rng.uniform(0, L, 2), rng)
        if f >= 18:  # debris of the dead cell X
            for _ in range(4):
                c = np.array([0.30 * L, 0.72 * L]) + rng.normal(0, 4, 2)
                lipids += micelle(c[0], c[1], 7, rng)

    lip = np.array(lipids) if lipids else np.zeros((0, 4, 2))
    lip = np.mod(lip, L)
    # remove overlapping molecules (greedy: later molecule loses)
    flat = lip.reshape(-1, 2)
    mol = np.repeat(np.arange(len(lip)), 4)
    tree = cKDTree(flat, boxsize=L)
    pr = tree.query_pairs(0.24, output_type="ndarray")
    if len(pr):
        mi, mj = mol[pr[:, 0]], mol[pr[:, 1]]
        diff = mi != mj
        drop = np.unique(np.maximum(mi[diff], mj[diff]))
        keep = np.ones(len(lip), bool); keep[drop] = False
        lip = lip[keep]
    nlip = len(lip)

    # water at rho = 3, excluded near lipid beads
    nw = int(3 * L * L) - 4 * nlip
    wpos = rng.uniform(0, L, (int(nw * 1.35), 2))
    if nlip:
        d, _ = cKDTree(lip.reshape(-1, 2), boxsize=L).query(wpos, k=1)
        wpos = wpos[d > 0.55]
    wpos = wpos[:nw]
    wt = np.full(len(wpos), W, np.uint8)

    # inside / outside classification of solvent beads; catalysts + nutrients
    inside_any = np.zeros(len(wpos), bool)
    for (P, na, nb, name) in lumens:
        c = P.mean(0)
        rel = wpos - c; rel -= L * np.round(rel / L)
        Pr = P - c
        path = Path(Pr)
        ins = path.contains_points(rel)
        if ins.any():
            dmin, _ = cKDTree(Pr).query(rel[ins])
            deep = np.nonzero(ins)[0][dmin > 2.6]
        else:
            deep = np.zeros(0, int)
        inside_any |= ins
        pick = rng.permutation(deep)
        k = min(len(pick), na + nb)
        wt[pick[:min(na, k)]] = KA
        wt[pick[min(na, k):k]] = KB
        rest = pick[k:]
        wt[rest[rng.random(len(rest)) < 0.03]] = N   # some nutrients got in
    outside = (~inside_any) & (wt == W)
    wt[outside & (rng.random(len(wt)) < 0.08)] = N
    # a few free catalysts in the medium
    freeK = np.nonzero(outside & (wt == W))[0]
    pick = rng.choice(freeK, 25, replace=False)
    wt[pick] = KA

    # assemble arrays: lipids first (H,T,T,T), then solvent
    lpos = lip.reshape(-1, 2)
    ltype = np.tile(np.array([H, T, T, T], np.uint8), nlip)
    base = np.arange(nlip) * 4
    bonds = np.concatenate([np.stack([base + k, base + k + 1], 1) for k in range(3)]) if nlip else np.zeros((0, 2), int)
    pos = np.vstack([lpos, wpos]) if nlip else wpos
    typ = np.concatenate([ltype, wt])
    # shuffle bead order (engines do not keep molecules contiguous necessarily)
    perm = rng.permutation(len(typ))
    inv = np.empty_like(perm); inv[perm] = np.arange(len(perm))
    pos = pos[perm]; typ = typ[perm]
    bonds = np.sort(inv[bonds], axis=1)
    return ocio.wrap(pos, L), typ, bonds, lumens


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir")
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--L", type=float, default=96.0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--snap-every", type=int, default=5000)
    ap.add_argument("--dt", type=float, default=0.04)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    L = a.L
    with open(os.path.join(a.outdir, "params.ini"), "w") as f:
        f.write("# SYNTHETIC test data made by tools/make_synthetic.py -- NOT a simulation\n")
        f.write(f"synthetic = 1\nstable_ids = 0\nL = {L}\nrho = 3\ndt = {a.dt}\nsteps = {a.frames * a.snap_every}\n")
        f.write(f"snap_every = {a.snap_every}\nseed = {a.seed}\nthreads = 1\ninit = soup\n")
        f.write("p_syn_a = 0.01\np_syn_b = 0.03\np_rep = 0.005\nmu = 0.01\nc_N = 0.08\n")
    stats_rows = []
    ev = []
    for fr in range(a.frames):
        step = fr * a.snap_every
        pos, typ, bonds, lumens = build_frame(fr, L, rng)
        ocio.write_snapshot(os.path.join(a.outdir, f"snap_{step:010d}.bin"), step, step * a.dt, L,
                            pos[:, 0], pos[:, 1], typ, bonds)
        cnt = np.bincount(typ, minlength=7)
        stats_rows.append((step, step * a.dt, 1.0 + rng.normal(0, 0.006), *cnt[:7], cnt[1], 0.71 + rng.normal(0, 0.03)))
        # events in the interval (step, step + snap_every): catalysis inside lumens
        kidx = np.nonzero((typ == KA) | (typ == KB))[0]
        for (P, na, nb, name) in lumens:
            c = P.mean(0)
            rel = pos[kidx] - c; rel -= L * np.round(rel / L)
            ins = kidx[Path(P - c).contains_points(rel)]
            for k in ins:
                var = "a" if typ[k] == KA else "b"
                rate = 2.0 if var == "a" else 6.0
                for _ in range(rng.poisson(rate)):
                    s = step + int(rng.integers(1, a.snap_every))
                    ev.append((s, "syn", int(k), pos[k, 0] + rng.normal(0, 0.4), pos[k, 1] + rng.normal(0, 0.4), var))
                for _ in range(rng.poisson(0.4 if var == "a" else 0.6)):
                    s = step + int(rng.integers(1, a.snap_every))
                    ev.append((s, "rep", int(k), pos[k, 0], pos[k, 1], var))
                    if rng.random() < 0.05:
                        ev.append((s, "mut", int(k), pos[k, 0], pos[k, 1], "b" if var == "a" else "a"))
        for _ in range(rng.poisson(6)):
            s = step + int(rng.integers(1, a.snap_every)); p = rng.uniform(0, L, 2)
            ev.append((s, "dlip", int(rng.integers(0, len(typ))), p[0], p[1], ""))
        for _ in range(rng.poisson(30)):
            s = step + int(rng.integers(1, a.snap_every)); p = rng.uniform(0, L, 2)
            ev.append((s, "dN", int(rng.integers(0, len(typ))), p[0], p[1], ""))
        for k in range(5):
            s = step + (k + 1) * a.snap_every // 6
            ev.append((s, "feed", int(rng.integers(20, 60)), -1.0, -1.0, ""))
        print(f"frame {fr:3d} step {step:8d}  N={len(typ)}  lipids={cnt[1]}  Ka={cnt[4]} Kb={cnt[5]}")
    with open(os.path.join(a.outdir, "stats.csv"), "w") as f:
        f.write("step,time,T_kin,nW,nH,nT,nN,nKa,nKb,nZ,n_lipids,max_bond\n")
        for r in stats_rows:
            f.write(f"{r[0]},{r[1]:.3f},{r[2]:.4f},{r[3]},{r[4]},{r[5]},{r[6]},{r[7]},{r[8]},{r[9]},{r[10]},{r[11]:.3f}\n")
    ev.sort(key=lambda e: e[0])
    with open(os.path.join(a.outdir, "events.csv"), "w") as f:
        f.write("step,kind,i,x,y,variant\n")
        for e in ev:
            f.write(f"{e[0]},{e[1]},{e[2]},{e[3] % L if e[3] >= 0 else -1:.3f},{e[4] % L if e[4] >= 0 else -1:.3f},{e[5]}\n")
    print(f"wrote {a.frames} snapshots, {len(ev)} events to {a.outdir}")


if __name__ == "__main__":
    main()
