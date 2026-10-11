#!/usr/bin/env python3
"""Check the structure-blind food supply from a run with snap_every = n_chem, no
catalysts and p_nd = 0 (every W -> N change between consecutive snapshots is then a
feed conversion of exactly the check at the later snapshot's step, at the positions
of that snapshot).
usage: feedcheck.py RUNDIR   (prints PASS/FAIL lines; exit code = number of failures)
Checks: conversions per check == feed events; conversions only from W; the region
(uniform: whole box, chi^2 test of uniformity; vent: every conversion inside the vent,
exact up to float32 rounding); per-check rate vs p_feed (binomial); global cap."""
import sys, glob, numpy as np
sys.path.insert(0, __import__('os').path.dirname(__file__))
from snapcheck import read_snap, mi

def params(run):
    p = {}
    for l in open(run + '/params.ini'):
        l = l.split('#')[0].strip()
        if '=' in l:
            k, v = (s.strip() for s in l.split('=', 1)); p[k] = v
    return p

def main(run):
    P = params(run)
    fails = 0
    def rep(ok, msg):
        nonlocal fails
        print(('PASS' if ok else 'FAIL') + '  ' + msg)
        fails += 0 if ok else 1
    mode, pf, cap = P['feed'], float(P['p_feed']), float(P['feed_cap'])
    snaps = sorted(glob.glob(run + '/snap_*.bin'))
    ev = {}
    for l in open(run + '/events.csv').readlines()[1:]:
        f = l.strip().split(',')
        if f[1] == 'feed': ev[int(f[0])] = ev.get(int(f[0]), 0) + int(f[2])
        elif f[1] in ('syn', 'rep', 'mut', 'dN'): raise SystemExit('feedcheck needs a run without catalysts and with p_nd = 0')
    prev = read_snap(snaps[0]); L = prev['L']; N = prev['N']
    xs, ys, nmis, nfromW, z, nWs, ks, nNmax = [], [], 0, 0, [], [], [], 0
    for p in snaps[1:]:
        s = read_snap(p)
        new = (prev['t'] != 3) & (s['t'] == 3)
        nfromW += int((prev['t'][new] == 0).sum())
        k = int(new.sum())
        nmis += k != ev.get(s['step'], 0)
        xs.append(s['x'][new]); ys.append(s['y'][new])
        if mode == 'uniform': nW = int((prev['t'] == 0).sum())
        else: nW = None
        nWs.append(nW); ks.append(k)
        nNmax = max(nNmax, int((s['t'] == 3).sum()))
        prev = s
    x = np.concatenate(xs).astype(float); y = np.concatenate(ys).astype(float)
    n = len(x)
    rep(nmis == 0 and n > 0 and nfromW == n,
        f'{mode}: {n} conversions in {len(snaps)-1} checks, all from W, per-check counts equal to the feed events ({nmis} mismatches)')
    if mode == 'uniform':
        g = 6
        h = np.histogram2d(x % L, y % L, bins=g, range=[[0, L], [0, L]])[0].ravel()
        e = n / g**2
        chi2 = ((h - e)**2 / e).sum(); dof = g * g - 1
        rep(chi2 < dof + 4 * np.sqrt(2 * dof), f'uniform: positions of new N on a {g}x{g} grid chi2={chi2:.1f} (dof {dof}, limit {dof + 4*np.sqrt(2*dof):.0f})')
        if cap == 0:
            ks_, nW_ = np.array(ks), np.array(nWs)
            expv = pf * nW_.sum(); sd = np.sqrt((pf * (1 - pf) * nW_).sum())
            rep(abs(ks_.sum() - expv) < 4 * sd, f'uniform: {ks_.sum()} conversions vs binomial expectation p_feed*sum(nW)={expv:.1f} +- {sd:.1f}')
    else:
        vx, vy, r, w, sh = float(P['vent_x']), float(P['vent_y']), float(P['vent_r']), float(P['vent_w']), P['vent_shape']
        if sh == 'disk': d = np.hypot(mi(x - vx, L), mi(y - vy, L)); lim = r
        elif sh == 'vstrip': d = np.abs(mi(x - vx, L)); lim = w / 2
        else: d = np.abs(mi(y - vy, L)); lim = w / 2
        # float32 snapshot positions: allow 1e-4
        rep(n > 0 and d.max() < lim + 1e-4, f'vent {sh}: max distance of a conversion from the vent {d.max():.4f} < {lim} (all {n} inside)')
        # the region is filled, not just its centre: compare mean distance with a uniform fill
        expd = 2 * lim / 3 if sh == 'disk' else lim / 2
        rep(abs(d.mean() - expd) < 0.1 * lim, f'vent {sh}: mean distance {d.mean():.3f} vs {expd:.3f} for a uniform fill')
    if cap > 0:
        lim = int(np.floor(cap * N + 1e-9))
        ok = nNmax <= lim and (nNmax == lim or mode != 'uniform')   # a uniform test run must reach the cap
        rep(ok, f'cap {cap}: max nN over the run {nNmax} <= floor(cap*N) = {lim} (reached: {nNmax == lim})')
    return fails

if __name__ == '__main__':
    sys.exit(sum(main(r) for r in sys.argv[1:]))
