#!/usr/bin/env python3
"""Tiny engine sanity checker (not the analysis toolkit; that lives in cel/tools).

usage:
  snapcheck.py stats  RUNDIR [t_equil]      mean/stderr of T_kin, max of max_bond
  snapcheck.py snap   SNAPFILE              header, type counts, bond lengths
  snapcheck.py rdf    SNAPFILE [type]       radial distribution function g(r)
  snapcheck.py cmp    SNAP_A SNAP_B         bitwise / max |dx| comparison
  snapcheck.py tclust SNAPFILE              tail-bead cluster statistics (aggregation)
"""
import sys, struct
import numpy as np

def read_snap(path):
    with open(path, 'rb') as f:
        b = f.read()
    if b[:4] != b'OCEL':
        raise SystemExit('bad magic')
    ver, N, nb = struct.unpack_from('<iii', b, 4)
    step, time, L = struct.unpack_from('<qdd', b, 16)
    o = 40
    x = np.frombuffer(b, '<f4', N, o); o += 4 * N
    y = np.frombuffer(b, '<f4', N, o); o += 4 * N
    t = np.frombuffer(b, 'u1', N, o); o += N
    bonds = np.frombuffer(b, '<i4', 2 * nb, o).reshape(nb, 2); o += 8 * nb
    assert o == len(b), (o, len(b))
    return dict(ver=ver, N=N, nb=nb, step=step, time=time, L=L, x=x, y=y, t=t, bonds=bonds)

def mi(d, L):
    return d - L * np.round(d / L)

def cmd_stats(run, teq=10.0):
    a = np.genfromtxt(run + '/stats.csv', delimiter=',', names=True)
    m = a['time'] >= teq
    T = a['T_kin'][m]
    # block average for an honest error bar
    nblk = 20
    blk = np.array([c.mean() for c in np.array_split(T, nblk)])
    print(f'rows={len(a)} t>={teq}: n={len(T)}  <T>={T.mean():.4f} +- {blk.std(ddof=1)/np.sqrt(nblk):.4f}'
          f'  (rel. dev {100*(T.mean()-1):+.2f}%)  first/second half: {T[:len(T)//2].mean():.4f} / {T[len(T)//2:].mean():.4f}')
    print(f'max_bond over run: {a["max_bond"].max():.4f}')

def cmd_snap(p):
    s = read_snap(p)
    names = ['W', 'H', 'T', 'N', 'Ka', 'Kb', 'Z']
    cnt = np.bincount(s['t'], minlength=7)
    print(f"step={s['step']} time={s['time']:.3f} L={s['L']} N={s['N']} nbonds={s['nb']}")
    print('  ' + ' '.join(f'{n}={c}' for n, c in zip(names, cnt)))
    print(f"  x range [{s['x'].min():.4f},{s['x'].max():.4f}] y range [{s['y'].min():.4f},{s['y'].max():.4f}]")
    if s['nb']:
        i, j = s['bonds'][:, 0], s['bonds'][:, 1]
        assert (i < j).all()
        d = np.hypot(mi(s['x'][j] - s['x'][i], s['L']), mi(s['y'][j] - s['y'][i], s['L']))
        print(f'  bond length mean={d.mean():.4f} std={d.std():.4f} max={d.max():.4f}')

def cmd_rdf(paths, typ=None):
    from scipy.spatial import cKDTree
    if isinstance(paths, str): paths = [paths]
    rmax, nbin = 3.0, 30
    gs = []
    for p in paths:
        s = read_snap(p)
        L = s['L']
        pos = np.c_[s['x'], s['y']].astype(np.float64) % L
        if typ is not None:
            pos = pos[s['t'] == int(typ)]
        n = len(pos)
        tr = cKDTree(pos, boxsize=L)
        pr = tr.query_pairs(rmax, output_type='ndarray')
        d = np.hypot(mi(pos[pr[:, 0], 0] - pos[pr[:, 1], 0], L), mi(pos[pr[:, 0], 1] - pos[pr[:, 1], 1], L))
        h, e = np.histogram(d, bins=nbin, range=(0, rmax))
        rho = n / L**2
        shell = np.pi * (e[1:]**2 - e[:-1]**2)
        gs.append(2 * h / (n * rho * shell))
    g = np.mean(gs, axis=0)
    rc = 0.5 * (e[1:] + e[:-1])
    print(f'g(r) averaged over {len(paths)} snapshot(s)')
    for r_, g_ in zip(rc, g):
        print(f'{r_:.3f} {g_:.4f} ' + '#' * int(40 * g_ / max(g.max(), 1e-9)))
    return rc, g

def cmd_cmp(a, b):
    A, B = read_snap(a), read_snap(b)
    same = all(np.array_equal(A[k], B[k]) for k in ('x', 'y', 't', 'bonds')) and A['step'] == B['step']
    dx = np.abs(A['x'].astype(float) - B['x']).max() if A['N'] == B['N'] else float('nan')
    print(f"step {A['step']} vs {B['step']}: bitwise identical={same}  max|dx|={dx:.3e}")
    return same

def cmd_tclust(p, rcut=1.0):
    from scipy.spatial import cKDTree
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    s = read_snap(p)
    L = s['L']
    sel = np.where(s['t'] == 2)[0]
    pos = np.c_[s['x'][sel], s['y'][sel]].astype(np.float64) % L
    tr = cKDTree(pos, boxsize=L)
    pr = tr.query_pairs(rcut, output_type='ndarray')
    n = len(sel)
    gph = coo_matrix((np.ones(len(pr)), (pr[:, 0], pr[:, 1])), shape=(n, n))
    nc, lab = connected_components(gph, directed=False)
    sz = np.bincount(lab)
    # fraction of T neighbours (within 1) that are T: local demixing measure
    alltr = cKDTree((np.c_[s['x'], s['y']].astype(np.float64)) % L, boxsize=L)
    nb_all = alltr.query_ball_point(pos, 1.0, return_length=True) - 1
    nb_t = tr.query_ball_point(pos, 1.0, return_length=True) - 1
    print(f"step={s['step']} nT={n} clusters={nc} largest={sz.max()} mean size (bead-weighted)={(sz**2).sum()/n:.1f}"
          f"  T-neighbour fraction={nb_t.sum()/max(nb_all.sum(),1):.3f}")

if __name__ == '__main__':
    c = sys.argv[1]
    if c == 'stats': cmd_stats(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 10.0)
    elif c == 'snap': cmd_snap(sys.argv[2])
    elif c == 'rdf': cmd_rdf([a for a in sys.argv[2:] if a.endswith('.bin')])
    elif c == 'cmp': sys.exit(0 if cmd_cmp(sys.argv[2], sys.argv[3]) else 1)
    elif c == 'tclust':
        for p in sys.argv[2:]: cmd_tclust(p)
    else: print(__doc__)
