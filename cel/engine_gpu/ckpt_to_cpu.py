#!/usr/bin/env python3
"""Reorder an oercel_gpu checkpoint so that the CPU reference engine continues it exactly.

usage:  ckpt_to_cpu.py IN_CKPT OUT_CKPT [--nsub 4]

Why: a checkpoint stores the per-bead arrays in the writing engine's slot order.  At a restart
the CPU engine (engine/oercel.c) re-sorts the beads into its own cell order but does NOT carry
the stored forces fx, fy along (it assumes the file is already in its order).  An oercel_gpu
checkpoint is in the GPU's cell order, so the CPU engine would start with forces belonging to
other beads for one step (measured: T jumps 1.04 -> 1.17 at the first step).  This tool
re-sorts the file into the CPU engine's order (stable sort by the reference cell index
cx * ncy + cy, ncx = floor(L), ncy = floor(L) * nsub, computed exactly as the C code does),
so its restart sort is the identity and the forces stay with their beads.

Use the CPU run's own `nsub` (default 4).  The physics state is unchanged (same beads, same
values, only the storage order and the nxt links are permuted).  Not needed for oercel_gpu
itself (it carries forces along when it re-sorts), and not needed once engine/oercel.c permutes
fx, fy at restart.  Formats: version 2 (linear lipids) and memB version 3.
"""
import argparse
import struct
import sys

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp')
    ap.add_argument('out')
    ap.add_argument('--nsub', type=int, default=4)
    a = ap.parse_args()
    b = open(a.inp, 'rb').read()
    if b[:4] != b'OCKP':
        sys.exit(f'{a.inp}: not an Oercel checkpoint')
    ver, N, ml, nH = struct.unpack_from('<iiii', b, 4)
    if ver not in (2, 3):
        sys.exit(f'{a.inp}: unsupported checkpoint version {ver}')
    o = 20 + (4 if ver == 3 else 0)
    step, time, L = struct.unpack_from('<qdd', b, o)
    o += 24 + 8 + 32 + 48          # seed, rng state, maxbond..soup_seed
    head = b[:o]
    sizes = [('<u4', 'gid'), ('u1', 'type'), ('i1', 'mpos'), ('<i4', 'nxt')] + [('<f8', k) for k in ('x', 'y', 'vx', 'vy', 'fx', 'fy')]
    arr = {}
    for dt, name in sizes:
        arr[name] = np.frombuffer(b, dt, N, o)
        o += np.dtype(dt).itemsize * N
    if b[o:o + 4] != b'END!' or o + 4 != len(b):
        sys.exit(f'{a.inp}: truncated or corrupt (end marker)')
    # reference cell index, exactly as engine/oercel.c sort_cells(): (int)(x * icsx) etc.
    ncx = int(np.floor(L))
    ncy = ncx * a.nsub
    icsx, icsy = ncx / L, ncy / L
    cx = np.minimum((arr['x'] * icsx).astype(np.int64), ncx - 1)
    cy = np.minimum((arr['y'] * icsy).astype(np.int64), ncy - 1)
    key = cx * ncy + cy
    src = np.argsort(key, kind='stable')          # new slot d <- old slot src[d]
    dest = np.empty(N, np.int64)
    dest[src] = np.arange(N)
    out = {k: v[src] for k, v in arr.items()}
    nx = out['nxt'].astype(np.int64)
    out['nxt'] = np.where(nx < 0, -1, dest[np.maximum(nx, 0)]).astype('<i4')
    with open(a.out + '.tmp', 'wb') as f:
        f.write(head)
        for dt, name in sizes:
            f.write(np.ascontiguousarray(out[name], dtype=dt).tobytes())
        f.write(b'END!')
    import os
    os.replace(a.out + '.tmp', a.out)
    moved = int((src != np.arange(N)).sum())
    print(f'{a.out}: step {step}, N={N}, L={L:g}, nsub={a.nsub}: {moved} of {N} beads re-slotted into the CPU engine order')


if __name__ == '__main__':
    main()
