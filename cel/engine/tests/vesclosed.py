#!/usr/bin/env python3
"""Is the seeded vesicle still closed?  For each snapshot: rasterise T beads on a
grid (cell GRID = engine feed_grid, a cell with >= 1 T is membrane), label 4-connected periodic
non-membrane regions, and test whether the region at the vesicle centre (start
at L/2,L/2, followed via the centre of mass of all lipid beads near it) is cut
off from the largest (outside) region.  usage: vesclosed.py RUNDIR"""
import sys, glob
GRID = 1.6  # same coarse grid as the engine feed (feed_grid)
import numpy as np
from scipy import ndimage
sys.path.insert(0, __import__('os').path.dirname(__file__))
from snapcheck import read_snap

def periodic_label(free):
    lab, n = ndimage.label(free)
    # merge labels across periodic boundaries
    parent = list(range(n + 1))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    for a, b in [(lab[0, :], lab[-1, :]), (lab[:, 0], lab[:, -1])]:
        for u, v in zip(a, b):
            if u and v: parent[find(u)] = find(v)
    return np.vectorize(lambda v: find(v) if v else 0)(lab)

def check(run):
    res = []
    for p in sorted(glob.glob(run + '/snap_*.bin')):
        s = read_snap(p); L = s["L"]; ng = int(L / GRID)
        tx = (s['x'][s['t'] == 2] * ng / L).astype(int) % ng
        ty = (s['y'][s['t'] == 2] * ng / L).astype(int) % ng
        mem = np.zeros((ng, ng), bool); mem[tx, ty] = True
        lab = periodic_label(~mem)
        sizes = np.bincount(lab.ravel()); sizes[0] = 0
        outside = sizes.argmax()
        c = ng // 2
        # centre region: any free cell within 2 of the box centre
        cen = lab[c - 1:c + 2, c - 1:c + 2].ravel(); cen = cen[cen > 0]
        closed = len(cen) > 0 and all(v != outside for v in cen)
        lumen = sizes[np.bincount(cen).argmax()] if len(cen) else 0
        res.append((s['step'], closed, lumen if closed else 0))
    return res

if __name__ == '__main__':
    for run in sys.argv[1:]:
        r = check(run)
        flags = ''.join('C' if c else '.' for _, c, _ in r)
        first_open = next((st for st, c, _ in r if not c), None)
        print(f'{run}: {flags}  first open at step {first_open}  final lumen cells {r[-1][2]}')
