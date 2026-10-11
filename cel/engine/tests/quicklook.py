#!/usr/bin/env python3
"""Engine sanity quick-look (NOT the project's renderer, which lives in cel/tools):
plain scatter plot of one or more snapshots, water omitted.
usage: quicklook.py out.png snap1.bin [snap2.bin ...]"""
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
sys.path.insert(0, __import__('os').path.dirname(__file__))
from snapcheck import read_snap, mi

out, snaps = sys.argv[1], sys.argv[2:]
n = len(snaps)
fig, axs = plt.subplots(1, n, figsize=(6 * n, 6.4), squeeze=False)
style = {1: ('#d62728', 7, 'H'), 2: ('#ff9f1c', 5, 'T'), 3: ('#4a90d9', 3, 'N'), 4: ('#2ca02c', 22, 'Ka'), 5: ('#b5e61d', 22, 'Kb')}
for ax, p in zip(axs[0], snaps):
    s = read_snap(p)
    L = s['L']
    if s['nb']:
        i, j = s['bonds'][:, 0], s['bonds'][:, 1]
        dx = mi(s['x'][j] - s['x'][i], L); dy = mi(s['y'][j] - s['y'][i], L)
        segs = np.stack([np.c_[s['x'][i], s['y'][i]], np.c_[s['x'][i] + dx, s['y'][i] + dy]], axis=1)
        from matplotlib.collections import LineCollection
        ax.add_collection(LineCollection(segs, colors='#999999', linewidths=0.4, zorder=1))
    for t, (c, sz, lab) in style.items():
        m = s['t'] == t
        if m.any():
            ax.scatter(s['x'][m], s['y'][m], s=sz * (64 / L) ** 2 * 0.5, c=c, lw=0, label=f'{lab} ({m.sum()})', zorder=2 + (t >= 4))
    ax.set_xlim(0, L); ax.set_ylim(0, L); ax.set_aspect('equal')
    ax.set_title(f"step {s['step']}  t = {s['time']:.0f}", fontsize=11)
    ax.legend(loc='upper right', fontsize=7, markerscale=2, framealpha=0.8)
    ax.set_xticks([]); ax.set_yticks([])
fig.tight_layout()
fig.savefig(out, dpi=110)
print('wrote', out)
