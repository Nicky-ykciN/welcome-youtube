#!/usr/bin/env python3
"""Statistical comparison of two Oercel runs (reference CPU engine vs oercel_gpu / oercel_emu).

usage:
  compare.py water    REF GPU [--teq 30]      kinetic T, total momentum, g(r), virial pressure
  compare.py bonds    REF GPU [--teq 30]      bond-length distribution, max bond, T, T-neighbour fraction
  compare.py vesicles REF1,REF2 GPU1,GPU2     closed vesicles per run (needs tools/analyze.py output cells.json)
  compare.py chem     REF GPU                 reaction/decay/feed event rates (per check) and species counts
  compare.py ident    RUN_A RUN_B [--after S] bitwise identity of stats.csv/events.csv rows after step S,
                                              of the common snapshots and of ckpt.bin
Every check prints PASS/FAIL; the exit code is the number of failed checks.
Needs numpy and scipy only (no project imports), so it runs anywhere.
"""
import argparse
import filecmp
import glob
import json
import os
import re
import struct
import sys

import numpy as np

FAILS = 0


def report(ok, msg):
    global FAILS
    print(('PASS  ' if ok else 'FAIL  ') + msg, flush=True)
    if not ok:
        FAILS += 1


def read_snap(path):
    with open(path, 'rb') as f:
        b = f.read()
    if b[:4] != b'OCEL':
        raise SystemExit(f'{path}: bad magic')
    ver, N, nb = struct.unpack_from('<iii', b, 4)
    step, time, L = struct.unpack_from('<qdd', b, 16)
    o = 40
    x = np.frombuffer(b, '<f4', N, o); o += 4 * N
    y = np.frombuffer(b, '<f4', N, o); o += 4 * N
    t = np.frombuffer(b, 'u1', N, o); o += N
    bonds = np.frombuffer(b, '<i4', 2 * nb, o).reshape(nb, 2); o += 8 * nb
    if o != len(b):
        raise SystemExit(f'{path}: size mismatch ({o} vs {len(b)})')
    return dict(N=N, nb=nb, step=step, time=time, L=L, x=x.astype(float), y=y.astype(float), t=t, bonds=bonds)


def stats(run):
    return np.genfromtxt(os.path.join(run, 'stats.csv'), delimiter=',', names=True)


def snaps(run, teq):
    out = []
    for p in sorted(glob.glob(os.path.join(run, 'snap_*.bin'))):
        h = read_snap(p)
        if h['time'] >= teq:
            out.append(h)
    return out


def mi(d, L):
    return d - L * np.round(d / L)


def tmean(run, teq, nblk=20):
    a = stats(run)
    T = a['T_kin'][a['time'] >= teq]
    blk = np.array([c.mean() for c in np.array_split(T, nblk)])
    return T.mean(), blk.std(ddof=1) / np.sqrt(nblk), T


def pmax(run):
    txt = open(os.path.join(run, 'log.txt')).read()
    p = [tuple(map(float, m)) for m in re.findall(r'p=\(([-0-9.e+]+),([-0-9.e+]+)\)', txt)]
    return max(max(abs(u), abs(v)) for u, v in p) if p else float('nan')


def rdf_and_virial(run, teq, a_ww=25.0):
    from scipy.spatial import cKDTree
    rmax, nbin = 3.0, 30
    gs, vir = [], []
    for s in snaps(run, teq):
        L = s['L']
        pos = np.c_[s['x'], s['y']] % L
        n = len(pos)
        tr = cKDTree(pos, boxsize=L)
        pr = tr.query_pairs(rmax, output_type='ndarray')
        d = np.hypot(mi(pos[pr[:, 0], 0] - pos[pr[:, 1], 0], L), mi(pos[pr[:, 0], 1] - pos[pr[:, 1], 1], L))
        h, e = np.histogram(d, bins=nbin, range=(0, rmax))
        rho = n / L**2
        shell = np.pi * (e[1:]**2 - e[:-1]**2)
        gs.append(2 * h / (n * rho * shell))
        r = d[d < 1.0]
        vir.append((a_ww * (1 - r) * r).sum() / (2 * L * L))  # (1/(2V)) sum_{i!=j} r F_C(r), pairs counted once x2 /2
    rc = 0.5 * (e[1:] + e[:-1])
    return rc, np.mean(gs, axis=0), np.array(vir), rho


def cmd_water(a):
    teq = a.teq
    Tr, er, _ = tmean(a.ref, teq)
    Tg, eg, Tall = tmean(a.gpu, teq)
    h1, h2 = Tall[:len(Tall) // 2].mean(), Tall[len(Tall) // 2:].mean()
    sig = np.hypot(er, eg)
    report(abs(Tg - 1) < 0.03 and abs(h1 - h2) < 0.01,
           f'gpu kinetic temperature <T>={Tg:.4f} +- {eg:.4f} ({100 * (Tg - 1):+.2f}% of kT, limit 3%), halves {h1:.4f}/{h2:.4f}')
    report(abs(Tg - Tr) < max(4 * sig, 0.003),
           f'<T> gpu {Tg:.4f} +- {eg:.4f} vs ref {Tr:.4f} +- {er:.4f}: diff {Tg - Tr:+.4f} (limit max(4 sigma, 0.003) = {max(4 * sig, 0.003):.4f})')
    pg, pr_ = pmax(a.gpu), pmax(a.ref)
    report(pg < 1e-8, f'gpu total momentum max|P| = {pg:.1e} (ref {pr_:.1e}; limit 1e-8)')
    r, gr, vr, rho = rdf_and_virial(a.ref, teq)
    _, gg, vg, _ = rdf_and_virial(a.gpu, teq)
    pkr, pkg = gr.argmax(), gg.argmax()
    dg = np.abs(gg - gr).max()
    report(pkr == pkg and dg < 0.03 and gg[0] < 0.1,
           f'g(r): first peak gpu {gg[pkg]:.3f} at r={r[pkg]:.2f} vs ref {gr[pkr]:.3f} at r={r[pkr]:.2f}; max|g_gpu - g_ref| = {dg:.4f} (limit 0.03); g(0.05) gpu {gg[0]:.3f}')
    Pr = rho * Tr + vr.mean()
    Pg = rho * Tg + vg.mean()
    ePr = np.hypot(rho * er, vr.std(ddof=1) / np.sqrt(len(vr))) if len(vr) > 1 else 0
    ePg = np.hypot(rho * eg, vg.std(ddof=1) / np.sqrt(len(vg))) if len(vg) > 1 else 0
    report(abs(Pg - Pr) / Pr < 0.01,
           f'pressure (rho kT_kin + conservative virial, from {len(vg)} snapshots): gpu {Pg:.3f} +- {ePg:.3f} vs ref {Pr:.3f} +- {ePr:.3f} '
           f'({100 * (Pg - Pr) / Pr:+.2f}%, limit 1%)')


def bond_lengths(run, teq, per_snap=False):
    ds = []
    for s in snaps(run, teq):
        if s['nb'] == 0:
            continue
        i, j = s['bonds'][:, 0], s['bonds'][:, 1]
        if not (i < j).all():
            raise SystemExit('bond list not i < j')
        ds.append(np.hypot(mi(s['x'][j] - s['x'][i], s['L']), mi(s['y'][j] - s['y'][i], s['L'])))
    if per_snap:
        return np.array([d.mean() for d in ds])
    return np.concatenate(ds) if ds else np.array([])


def sem_of_mean(run, teq):
    """honest standard error of the run's mean bond length: per-snapshot means are correlated
    through the slowly changing aggregate structure, so use block averages (or, with few
    snapshots, the lag-1 autocorrelation correction)"""
    m = bond_lengths(run, teq, per_snap=True)
    n = len(m)
    if n >= 16:
        blk = np.array([b.mean() for b in np.array_split(m, 8)])
        return blk.std(ddof=1) / np.sqrt(8)
    if n >= 3:
        rho = np.clip(np.corrcoef(m[:-1], m[1:])[0, 1], 0.0, 0.9)
        return m.std(ddof=1) / np.sqrt(n) * np.sqrt((1 + rho) / (1 - rho))
    return float('nan')


def tfrac(s):
    from scipy.spatial import cKDTree
    L = s['L']
    pos = np.c_[s['x'], s['y']] % L
    tt = pos[s['t'] == 2]
    if len(tt) == 0:
        return float('nan')
    na = cKDTree(pos, boxsize=L).query_ball_point(tt, 1.0, return_length=True) - 1
    nb = cKDTree(tt, boxsize=L).query_ball_point(tt, 1.0, return_length=True) - 1
    return nb.sum() / na.sum()


def cmd_bonds(a):
    teq = a.teq
    br, bg = bond_lengths(a.ref, teq), bond_lengths(a.gpu, teq)
    # limits = max(fixed tolerance, 4 standard errors of the difference of the run means)
    se_m = np.hypot(sem_of_mean(a.gpu, teq), sem_of_mean(a.ref, teq))
    if not np.isfinite(se_m):
        se_m = np.sqrt(3 * (bg.var() / len(bg) + br.var() / len(br)))
    lim_m = max(0.002 * br.mean(), 4 * se_m)
    lim_s = max(0.03, 4 * np.sqrt(0.5 / len(bg) + 0.5 / len(br)))
    report(len(bg) > 0 and abs(bg.mean() - br.mean()) < lim_m and abs(bg.std() - br.std()) / br.std() < lim_s,
           f'bond length gpu mean {bg.mean():.4f} std {bg.std():.4f} vs ref mean {br.mean():.4f} std {br.std():.4f} '
           f'({len(bg)} / {len(br)} bonds; limits |d mean| < {lim_m:.4f}, |d std|/std < {100 * lim_s:.1f}%)')
    qs = [0.01, 0.5, 0.99]
    print('      quantiles 1/50/99%: gpu ' + ' '.join(f'{v:.4f}' for v in np.quantile(bg, qs)) +
          '  ref ' + ' '.join(f'{v:.4f}' for v in np.quantile(br, qs)))
    mg, mr = stats(a.gpu)['max_bond'].max(), stats(a.ref)['max_bond'].max()
    report(mg < 1.5, f'max bond over all steps gpu {mg:.3f} (ref {mr:.3f}; SPEC limit 1.5)')
    Tr, er, _ = tmean(a.ref, teq)
    Tg, eg, _ = tmean(a.gpu, teq)
    report(abs(Tg - Tr) < max(4 * np.hypot(er, eg), 0.004) and abs(Tg - 1) < 0.03,
           f'<T> with lipids gpu {Tg:.4f} +- {eg:.4f} vs ref {Tr:.4f} +- {er:.4f}')
    sg, sr = snaps(a.gpu, 0), snaps(a.ref, 0)
    fg, fr = tfrac(sg[-1]), tfrac(sr[-1])
    report(abs(fg - fr) < 0.05, f'T-neighbour fraction (aggregation) at step {sg[-1]["step"]}: gpu {fg:.3f} vs ref {fr:.3f} (limit 0.05)')


def vesicle_series(run):
    p = os.path.join(run, 'cells.json')
    d = json.load(open(p))
    fr = d['frames']
    return np.array([f['step'] for f in fr]), np.array([f['n_cells'] for f in fr])


def cmd_vesicles(a):
    def summ(runs):
        out = []
        for r in runs.split(','):
            st, n = vesicle_series(r)
            k = max(1, len(n) // 3)
            out.append((os.path.basename(r.rstrip('/')), st[-1], n[-1], n.max(), n[-k:].mean()))
        return out
    R, G = summ(a.ref), summ(a.gpu)
    for nm, st, last, mx, tail in R + G:
        print(f'      {nm:28s} step {st}: closed vesicles last={last} max={mx} mean(last third)={tail:.2f}')
    rl = [x[4] for x in R]
    gl = [x[4] for x in G]
    lo, hi = min(rl), max(rl)
    tol = max(1.5, 0.5 * np.mean(rl))       # seed-to-seed scatter of a small box is large
    ok = all(lo - tol <= g <= hi + tol for g in gl) and abs(np.mean(gl) - np.mean(rl)) <= tol
    report(ok, f'closed vesicles (mean over the last third of the snapshots): gpu {", ".join(f"{g:.2f}" for g in gl)} vs ref '
               f'{", ".join(f"{r:.2f}" for r in rl)}; accepted range [{lo - tol:.2f}, {hi + tol:.2f}]')


def read_events(run):
    rows = []
    p = os.path.join(run, 'events.csv')
    with open(p) as f:
        next(f)
        for l in f:
            q = l.rstrip('\n').split(',')
            rows.append((int(q[0]), q[1], int(q[2])))
    return rows


def chem_summary(runs):
    """sum event counts over a comma-separated list of runs; also catalyst-checks"""
    cnt, kchecks, nchecks = {}, 0.0, 0
    for run in runs.split(','):
        ev = read_events(run)
        st = stats(run)
        par = {}
        for l in open(os.path.join(run, 'params.ini')):
            l = l.split('#')[0]
            if '=' in l:
                k, v = (u.strip() for u in l.split('=', 1))
                par[k] = v
        nchem = int(par['n_chem'])
        nc = int(st['step'].max()) // nchem
        nchecks += nc
        kchecks += (st['nKa'] + st['nKb']).mean() * nc
        for s_, k, i in ev:
            cnt[k] = cnt.get(k, 0) + (i if k == 'feed' else 1)
    return cnt, kchecks, nchecks


def cmd_chem(a):
    r, rk, rn = chem_summary(a.ref)
    g, gk, gn = chem_summary(a.gpu)
    for nm, c, k, n in (('ref', r, rk, rn), ('gpu', g, gk, gn)):
        print(f'      {nm}: {n} checks, {k:.0f} catalyst-checks; events ' + ' '.join(f'{e}={v}' for e, v in sorted(c.items())))
    # Event totals of independent stochastic runs: compare as Poisson counts, but the catalyst
    # population itself fluctuates from run to run (birth-death), so syn/rep are also compared per
    # catalyst-check.  Limits: |z| < 4.5, or within 15 %.
    # feed: with a binding feed_cap the conversions just replace what was consumed, so the total is
    # not an independent rate; check the balance instead (feedcheck.py tests the rate itself)
    for nm, c in (('ref', r), ('gpu', g)):
        used = 4 * c.get('syn', 0) + 2 * (c.get('rep', 0) + c.get('mut', 0)) + c.get('dN', 0)
        print(f'      {nm}: feed {c.get("feed", 0)} vs nutrients consumed (4 syn + 2 rep + dN for H-T-T-T) {used}')
    for k in ('syn', 'rep', 'mut', 'dlip', 'dK', 'dN'):
        cr, cg = r.get(k, 0), g.get(k, 0)
        if cr + cg == 0:
            continue
        z = (cg - cr) / np.sqrt(max(cr + cg, 1))
        msg = f'{k:5s} events gpu {cg} vs ref {cr} (z = {z:+.2f})'
        ok = abs(z) < 4.5 or abs(cg - cr) <= 0.15 * max(cr, cg)
        if k in ('syn', 'rep') and rk > 0 and gk > 0:
            fr, fg = cr / rk, cg / gk
            # Poisson error of the ratio
            zr = (fg - fr) / np.sqrt(max(cr, 1) / rk**2 + max(cg, 1) / gk**2)
            msg += f'; per catalyst-check gpu {fg:.3e} vs ref {fr:.3e} (z = {zr:+.2f})'
            ok = ok and (abs(zr) < 4.5 or abs(fg - fr) <= 0.15 * max(fr, fg))
        report(ok, msg)


def cmd_ident(a):
    after = a.after
    def rows(p):
        if not os.path.exists(p):
            return None
        with open(p) as f:
            lines = f.readlines()[1:]
        return [l for l in lines if int(l.split(',')[0]) > after]
    for fn in ('stats.csv', 'events.csv'):
        ra, rb = rows(os.path.join(a.run_a, fn)), rows(os.path.join(a.run_b, fn))
        if ra is None and rb is None:
            continue
        report(ra == rb, f'{fn}: {len(ra or [])} rows after step {after} identical ({fn})')
    sa = {os.path.basename(p) for p in glob.glob(os.path.join(a.run_a, 'snap_*.bin'))}
    sb = {os.path.basename(p) for p in glob.glob(os.path.join(a.run_b, 'snap_*.bin'))}
    common = sorted(n for n in sa & sb if int(n[5:15]) > after)
    same = all(filecmp.cmp(os.path.join(a.run_a, n), os.path.join(a.run_b, n), shallow=False) for n in common)
    report(len(common) > 0 and same, f'{len(common)} common snapshots after step {after} bitwise identical')
    ca, cb = os.path.join(a.run_a, 'ckpt.bin'), os.path.join(a.run_b, 'ckpt.bin')
    if os.path.exists(ca) and os.path.exists(cb):
        report(filecmp.cmp(ca, cb, shallow=False), 'final ckpt.bin bitwise identical')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('water', 'bonds', 'chem'):
        p = sub.add_parser(c)
        p.add_argument('ref')
        p.add_argument('gpu')
        p.add_argument('--teq', type=float, default=30.0)
    p = sub.add_parser('vesicles')
    p.add_argument('ref')
    p.add_argument('gpu')
    p = sub.add_parser('ident')
    p.add_argument('run_a')
    p.add_argument('run_b')
    p.add_argument('--after', type=int, default=0)
    a = ap.parse_args()
    dict(water=cmd_water, bonds=cmd_bonds, vesicles=cmd_vesicles, chem=cmd_chem, ident=cmd_ident)[a.cmd](a)
    sys.exit(FAILS)


if __name__ == '__main__':
    main()
