"""Cell detection in one snapshot (SPEC section 7), periodic-boundary aware.

Algorithm
  1. lipid molecules = connected components of bonds between H/T beads
  2. membranes ("aggregates") = molecules connected by tail-tail proximity (T-T distance < r_tail)
  3. every aggregate with >= min_membrane_lipids molecules is unwrapped across the periodic
     boundaries by a breadth-first walk over its bead graph (bonds + tail contacts).  If the
     walk is inconsistent (the aggregate wraps around the torus) the aggregate is rasterised on
     the full periodic grid instead.
  4. the aggregate's H+T beads are rasterised on a fine grid (pixel h ~ 0.25) as disks of radius
     r_stamp; holes = solvent regions not connected to the outside (4-connectivity) - on the
     torus 'outside' means: the solvent region wraps around the torus (non-contractible).
  5. a hole is a lumen (= cell) when its area >= min_lumen_area and it holds enough
     hydrophilic beads (W/N/K) to be aqueous.
  6. lipids of the aggregate are assigned to the nearest of its lumens; per-cell contents are
     counted on a global periodic label grid (smaller, nested lumens painted last).

Scaling (boxes up to L = 2048, i.e. 12.6 M beads and an 8192^2 pixel grid):
  * non-wrapping aggregates are rasterised in their own small bounding box (as before);
  * wrapping aggregates are labelled on ONE periodic copy of the grid; contractible holes are
    found from the shifts of the components across the box edges (a component that meets
    itself with a non-zero shift wraps the torus).  This replaces the former 3x3 tiling with a
    floating-point distance transform (9x the pixels, 16 bytes per pixel);
  * disks are stamped by a periodic boolean dilation instead of a distance transform;
  * the distance from lumen walls to the bulk medium is computed in a window around each
    lumen (exact up to the window margin, which is larger than the wall-thickness limit; the
    only values that are used are those below that limit: the exposure test, and the median
    wall thickness of cells that passed it);
  * all full-grid arrays are bool or int32; per-bead work is restricted to lipid beads where
    possible.
Results are identical to the former implementation (checked on real runs, see tools/NOTES.md).
"""
import numpy as np
from scipy import ndimage
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components, breadth_first_order
from scipy.spatial import cKDTree, ConvexHull, QhullError

from ocio import W, H, T, N, KA, KB, Z

DEFAULTS = dict(
    r_tail=1.0,               # tail-tail proximity defining one membrane (SPEC)
    h=0.25,                   # raster pixel size (sim units); adjusted so L/h is integer
    r_stamp=0.75,             # disk radius drawn around each membrane bead
    min_membrane_lipids=12,   # smaller aggregates (micelles) cannot be a membrane
    min_lumen_area=16.0,      # unit^2 (smaller enclosed pockets in real runs were never vesicles)
    min_aqueous_frac=0.30,    # hydrophilic beads in lumen >= frac * rho * area
    rho=3.0,
    pad=2.5,                  # padding around an aggregate's bounding box (units)
    leaflet_in=1.5,           # head within this distance of the lumen = inner leaflet
    leaflet_max=6.0,          # heads further than this are not counted as wall heads
    min_exposure=0.8,         # fraction of the lumen boundary that must lie within one membrane
                              # thickness of the bulk outside medium (rejects water pockets
                              # buried in a lipid matrix / inverted phases)
    wall_extra=4.0,           # wall_max = 2 * lipid length * r0 + wall_extra (units)
    inner_frac_range=(0.2, 0.62),  # bilayer: wall heads face both the lumen and the medium
                                   # (vesicles 0.34-0.47; inverted pockets 0.7-1.0)
)

_S4 = ndimage.generate_binary_structure(2, 1)
INT16_LABELS = 32767      # label grids are int16 below this many lumens, int32 above (no overflow)


def minimg(d, L):
    return d - L * np.round(d / L)


def lipid_molecules(types, bonds):
    """mol[i] = molecule index for H/T beads (bonded H/T components), -1 otherwise."""
    n = len(types)
    lip = (types == H) | (types == T)
    idx = np.nonzero(lip)[0]
    mol = np.full(n, -1, np.int64)
    if len(idx) == 0:
        return mol, 0
    remap = np.full(n, -1, np.int64)
    remap[idx] = np.arange(len(idx))
    if len(bonds):
        b = bonds[lip[bonds[:, 0]] & lip[bonds[:, 1]]]
    else:
        b = np.zeros((0, 2), np.int64)
    m = len(idx)
    g = coo_matrix((np.ones(len(b)), (remap[b[:, 0]], remap[b[:, 1]])), shape=(m, m))
    nmol, lab = connected_components(g, directed=False)
    mol[idx] = lab
    return mol, nmol


def _unwrap_tree(pos, n, edges, L):
    """Unwrap a connected bead graph. Returns (U, wraps). pos (n,2), edges (k,2) local idx."""
    g = coo_matrix((np.ones(len(edges)), (edges[:, 0], edges[:, 1])), shape=(n, n)).tocsr()
    order, pred = breadth_first_order(g, 0, directed=False, return_predecessors=True)
    del g
    if len(order) != n:
        raise RuntimeError("unwrap: graph not connected")
    pred = pred.copy()
    pred[0] = 0
    D = minimg(pos - pos[pred], L)
    D[0] = 0.0
    # exact sequential accumulation in BFS order (python floats are fast enough here)
    ux = [0.0] * n; uy = [0.0] * n
    px = pos[:, 0].tolist(); py = pos[:, 1].tolist()
    ux[0] = px[0]; uy[0] = py[0]
    Dx = D[:, 0].tolist(); Dy = D[:, 1].tolist(); pr = pred.tolist()
    del D, pred
    for i in order[1:].tolist():
        p = pr[i]
        ux[i] = ux[p] + Dx[i]; uy[i] = uy[p] + Dy[i]
    U = np.stack([np.array(ux), np.array(uy)], 1)
    # free the per-bead python lists (~250 bytes per bead) before the edge test below
    del ux, uy, px, py, Dx, Dy, pr, order
    # wrap test in blocks of edges: same answer, bounded temporaries (a giant network at
    # L = 2048 has ~7 M edges; the unblocked test needed ~8 arrays of 16 bytes per edge)
    wraps = False
    for s in range(0, len(edges), _EDGE_BLOCK):
        e = edges[s:s + _EDGE_BLOCK]
        du = U[e[:, 1]] - U[e[:, 0]]
        dm = minimg(pos[e[:, 1]] - pos[e[:, 0]], L)
        if np.any(np.abs(du - dm) > 0.5 * L):
            wraps = True
            break
    return U, wraps


_EDGE_BLOCK = 1 << 19


def _bincount_blocks(flat, n, block=1 << 22):
    """np.bincount(flat, minlength=n) for a big int32/int16 label array, in blocks (np.bincount
    makes an 8-byte copy of its whole input; this keeps that copy to one block).  Same result."""
    if flat.size <= block:
        return np.bincount(flat, minlength=n)
    cnt = np.zeros(n, np.int64)
    for s in range(0, flat.size, block):
        c = np.bincount(flat[s:s + block], minlength=n)
        cnt[:len(c)] += c
    return cnt



def _disk_offsets(r_pix):
    """Pixel offsets of a disk: exactly the pixels whose Euclidean distance (as computed by
    ndimage.distance_transform_edt) to the centre is <= r_pix."""
    R = int(np.floor(r_pix))
    di, dj = np.mgrid[-R:R + 1, -R:R + 1]
    m = np.sqrt((di * di + dj * dj).astype(np.float64)) <= r_pix
    return [(int(a), int(b)) for a, b in zip(di[m].tolist(), dj[m].tolist())]


def _dilate_periodic(pts, offs):
    """Periodic dilation of a bool grid by a set of offsets (== EDT(~pts) <= r on the torus)."""
    out = np.zeros_like(pts)
    for a, b in offs:
        out |= np.roll(pts, (a, b), axis=(0, 1))
    return out


def _bulk_outside(memb):
    """Bulk solvent on the periodic grid: largest periodic solvent component (+ any >= 25 %)."""
    sol = ~memb
    lab, nl = ndimage.label(sol, structure=_S4)
    if nl == 0:
        return np.zeros_like(sol)
    pa = []
    for a_, b_ in ((lab[:, 0], lab[:, -1]), (lab[0, :], lab[-1, :])):
        m = (a_ > 0) & (b_ > 0)
        pa.append(np.stack([a_[m], b_[m]], 1).astype(np.int64))
    pa = np.vstack(pa)
    g = coo_matrix((np.ones(len(pa)), (pa[:, 0], pa[:, 1])), shape=(nl + 1, nl + 1))
    _, root = connected_components(g, directed=False)
    cnt = _bincount_blocks(lab.ravel(), nl + 1)
    area = np.zeros(int(root.max()) + 1, np.int64)
    np.add.at(area, root, cnt)
    area[root[0]] = 0                      # label 0 = membrane pixels
    tot = area.sum()
    big = (area == area.max()) | (area >= 0.25 * tot)
    out = big[root][lab]
    out &= sol
    return out


def _stamp_mask(pix, shape, r_pix):
    """Boolean mask of disks of radius r_pix (pixels) around integer pixel coords."""
    pts = np.zeros(shape, bool)
    pts[pix[:, 0], pix[:, 1]] = True
    dist = ndimage.distance_transform_edt(~pts)
    return dist <= r_pix


def _holes_local(memb):
    """Labels of solvent components not touching the border. Returns (lab, ids)."""
    lab, nl = ndimage.label(~memb, structure=_S4)
    if nl == 0:
        return lab, []
    border = np.unique(np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]]))
    ids = np.setdiff1d(np.arange(1, nl + 1), border)
    return lab, ids.tolist()


def _holes_torus(gpix, ng, offs, min_px=0):
    """Enclosed (contractible) solvent regions of a membrane wrapping the periodic box.

    The membrane is stamped on one periodic copy of the grid and its solvent labelled.  A solvent
    component that continues across a box edge is followed through its copies; if it meets
    itself with a non-zero shift it wraps the torus (not enclosed).  Every enclosed component is
    returned once, as unwrapped pixel coordinates (k,2) (may be negative / > ng) of the copy
    whose centroid lies in [0, ng)^2, pixels in raster order; the list is in raster order of the
    first pixel.  This is exactly what the former 3x3-tiling implementation returned (for holes
    smaller than the box).  Holes with fewer than min_px pixels are counted but not returned.

    Returns (holes, n_holes)."""
    pts = np.zeros((ng, ng), bool)
    pts[gpix[:, 0] % ng, gpix[:, 1] % ng] = True
    memb = _dilate_periodic(pts, offs)
    del pts
    lab, nl = ndimage.label(~memb, structure=_S4)
    del memb
    if nl == 0:
        return [], 0
    adj = {}
    for a_, b_, sx, sy in ((lab[-1, :], lab[0, :], 1, 0), (lab[:, -1], lab[:, 0], 0, 1)):
        m = (a_ > 0) & (b_ > 0)
        if m.any():
            uv = np.unique(np.stack([a_[m], b_[m]], 1), axis=0)
            for u, v in uv.tolist():
                adj.setdefault(u, []).append((v, sx, sy))
                adj.setdefault(v, []).append((u, -sx, -sy))
    cnt = _bincount_blocks(lab.ravel(), nl + 1)
    comps = []                      # (labels, offsets) of enclosed components
    off = {}
    for s in adj:
        if s in off:
            continue
        off[s] = (0, 0)
        stack = [s]; members = [s]; wraps = False
        while stack:
            u = stack.pop()
            ou = off[u]
            for v, sx, sy in adj[u]:
                ov = (ou[0] + sx, ou[1] + sy)
                if v not in off:
                    off[v] = ov; stack.append(v); members.append(v)
                elif off[v] != ov:
                    wraps = True
        if not wraps:
            comps.append(members)
    singles = np.ones(nl + 1, bool)
    singles[0] = False
    if adj:
        singles[np.fromiter(adj.keys(), np.int64)] = False
    n_holes = int(singles.sum()) + len(comps)
    keep_single = np.nonzero(singles & (cnt >= max(min_px, 1)))[0]
    keep_comp = [mm for mm in comps if int(cnt[mm].sum()) >= max(min_px, 1)]
    if len(keep_single) == 0 and not keep_comp:
        return [], n_holes
    objs = ndimage.find_objects(lab)

    def pix_of(l):
        sl = objs[l - 1]
        ii, jj = np.nonzero(lab[sl] == l)
        return ii + sl[0].start, jj + sl[1].start

    out = []
    for l in keep_single.tolist():
        ii, jj = pix_of(l)
        out.append((ii, jj))
    for mm in keep_comp:
        I, J = [], []
        for l in mm:
            ii, jj = pix_of(l)
            o = off[l]
            I.append(ii + o[0] * ng); J.append(jj + o[1] * ng)
        ii = np.concatenate(I); jj = np.concatenate(J)
        o = np.lexsort((jj, ii))
        out.append((ii[o], jj[o]))
    del lab, objs
    res = []
    for q in range(len(out)):
        ii, jj = out[q]
        out[q] = None                  # free as we go: a sponge network can enclose most of the box
        # the copy whose centroid lies in the centre tile of a 3x3 tiling (same test as before)
        si = int(np.floor(ii.mean() / ng)); sj = int(np.floor(jj.mean() / ng))
        for _ in range(4):
            bi = ii - si * ng + ng; bj = jj - sj * ng + ng
            ci, cj = bi.mean(), bj.mean()
            di = -1 if ci < ng else (1 if ci >= 2 * ng else 0)
            dj = -1 if cj < ng else (1 if cj >= 2 * ng else 0)
            if di == 0 and dj == 0:
                break
            si += di; sj += dj
        res.append(np.stack([bi - ng, bj - ng], 1))
    res.sort(key=lambda p: (int(p[0, 0]), int(p[0, 1])))
    return res, n_holes


def _dist_window(mask, pix, ng, M, block=1024):
    """Euclidean pixel distance from each pixel of pix (k,2, unwrapped coords) to the nearest True
    pixel of the periodic bool grid mask.  Exact for distances <= M; larger distances come out
    >= M (or inf when no True pixel lies within M of the whole window).  Works in windows of at
    most (block + 2M)^2 pixels."""
    out = np.empty(len(pix), np.float64)
    if len(pix) == 0:
        return out
    key = (pix[:, 0] // block) * 1000003 + (pix[:, 1] // block)
    ukeys, inv = np.unique(key, return_inverse=True)
    for u in range(len(ukeys)):
        sel = np.nonzero(inv == u)[0] if len(ukeys) > 1 else np.arange(len(pix))
        p = pix[sel]
        lo = p.min(0) - M
        hi = p.max(0) + M + 1
        wi = np.arange(lo[0], hi[0]) % ng
        wj = np.arange(lo[1], hi[1]) % ng
        win = mask[np.ix_(wi, wj)]
        if not win.any():
            out[sel] = np.inf
            continue
        d = ndimage.distance_transform_edt(~win)
        out[sel] = d[p[:, 0] - lo[0], p[:, 1] - lo[1]]
    return out


def _boundary(gp_mod, label, k, ng):
    """Pixels (periodic coords) of lumen k with a 4-neighbour whose label is not k."""
    isb = np.zeros(len(gp_mod), bool)
    for d_ in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nbx = (gp_mod + d_) % ng
        isb |= label[nbx[:, 0], nbx[:, 1]] != k
    return isb


def detect(snap, cfg=None):
    """Detect cells in a Snapshot. Returns dict with 'cells' (list of dict), 'label' (ng x ng
    global lumen label grid, -1 = none; int16, or int32 when there are >= 32767 cells),
    'bead_cell' (int32 per bead: c >= 0 solvent bead in the lumen of cell c; -c-2 lipid bead in
    the membrane of cell c; -1 otherwise), 'h', 'ng', 'aggregates' (summary)."""
    c = dict(DEFAULTS)
    if cfg:
        c.update(cfg)
    L = snap.L
    ng = int(round(L / c["h"]))
    h = L / ng
    r_pix = c["r_stamp"] / h
    offs = _disk_offsets(r_pix)
    types = snap.type
    X = snap.x; Y = snap.y
    nb = len(types)

    def P(idx):
        return np.stack([X[idx], Y[idx]], 1)

    mol, nmol = lipid_molecules(types, snap.bonds)
    tidx = np.nonzero(types == T)[0]
    agg_of_mol = np.arange(nmol)
    pairs = np.zeros((0, 2), np.int64)
    if len(tidx) > 1 and nmol > 0:
        tree = cKDTree(P(tidx), boxsize=L)
        pr = tree.query_pairs(c["r_tail"], output_type="ndarray")
        del tree
        if len(pr):
            pairs = np.stack([tidx[pr[:, 0]], tidx[pr[:, 1]]], 1)
            del pr
            mi, mj = mol[pairs[:, 0]], mol[pairs[:, 1]]
            g = coo_matrix((np.ones(len(mi)), (mi, mj)), shape=(nmol, nmol))
            _, agg_of_mol = connected_components(g, directed=False)
            del g, mi, mj
    nagg = int(agg_of_mol.max()) + 1 if nmol else 0
    agg_size = np.bincount(agg_of_mol, minlength=nagg) if nmol else np.zeros(0, int)
    bead_agg = np.full(nb, -1, np.int64)
    lipmask = mol >= 0
    lip_idx = np.nonzero(lipmask)[0]
    bead_agg[lip_idx] = agg_of_mol[mol[lip_idx]]

    # bead-level edges inside lipids: bonds between lipid beads + tail contacts
    if len(snap.bonds):
        lb = snap.bonds[lipmask[snap.bonds[:, 0]] & lipmask[snap.bonds[:, 1]]]
    else:
        lb = np.zeros((0, 2), np.int64)
    all_edges = np.vstack([lb, pairs]) if len(pairs) else lb
    del pairs
    edge_agg = bead_agg[all_edges[:, 0]] if len(all_edges) else np.zeros(0, np.int64)

    cand_aggs = np.nonzero(agg_size >= c["min_membrane_lipids"])[0]
    # group lipid beads and edges by aggregate (within an aggregate: increasing bead index)
    agl = bead_agg[lip_idx]
    order_l = np.argsort(agl, kind="stable")
    sb = agl[order_l]
    order_b = lip_idx[order_l]
    del agl, order_l
    loc = np.full(nb, -1, np.int64)          # index of a lipid bead inside its aggregate
    loc[order_b] = np.arange(len(order_b)) - np.searchsorted(sb, sb)
    order_e = np.argsort(edge_agg, kind="stable")
    se = edge_agg[order_e]

    # holes below this pixel count can never reach min_lumen_area (permissive; the exact area test
    # follows below)
    min_px = max(0, int(np.floor(c["min_lumen_area"] / (h * h))) - 1)
    lumens = []   # dicts: agg, gpix (k,2) unwrapped global pixel coords, wraps
    agg_info = []
    for a in cand_aggs.tolist():
        b0, b1 = np.searchsorted(sb, a), np.searchsorted(sb, a, "right")
        beads = order_b[b0:b1]
        e0, e1 = np.searchsorted(se, a), np.searchsorted(se, a, "right")
        E = all_edges[order_e[e0:e1]]
        El = loc[E]
        pb = P(beads)
        U, wraps = _unwrap_tree(pb, len(beads), El, L)
        holes = []
        n_holes = 0
        if not wraps:
            lo = np.floor((U.min(0) - c["pad"]) / h).astype(np.int64)
            hi = np.ceil((U.max(0) + c["pad"]) / h).astype(np.int64)
            shape = tuple((hi - lo + 1).tolist())
            if shape[0] * shape[1] > 9 * ng * ng:   # absurdly large, treat as wrapping
                wraps = True
            else:
                pix = np.floor(U / h).astype(np.int64) - lo
                memb = _stamp_mask(pix, shape, r_pix)
                lab, ids = _holes_local(memb)
                n_holes = len(ids)
                if ids:
                    objs = ndimage.find_objects(lab)
                    for l in ids:
                        sl = objs[l - 1]
                        ii, jj = np.nonzero(lab[sl] == l)
                        holes.append(np.stack([ii + sl[0].start + lo[0], jj + sl[1].start + lo[1]], 1))
        if wraps:
            gp = np.floor(pb / h).astype(np.int64)
            holes, n_holes = _holes_torus(gp, ng, offs, min_px)
        agg_info.append(dict(agg=a, n_lipids=int(agg_size[a]), wraps=wraps, n_holes=n_holes))
        for hp in holes:
            area = len(hp) * h * h
            if area >= c["min_lumen_area"]:
                lumens.append(dict(agg=a, gpix=hp, area_raw=area, wraps_agg=wraps))
    del loc, all_edges, edge_agg, order_e, se

    # ---- global label grid (largest first so nested lumens overwrite)
    lumens.sort(key=lambda d: -d["area_raw"])
    ldt = np.int16 if len(lumens) < INT16_LABELS else np.int32     # never overflows; int16 saves memory
    label = np.full((ng, ng), -1, ldt)
    for k, lu in enumerate(lumens):
        gp = lu["gpix"] % ng
        label[gp[:, 0], gp[:, 1]] = k
    gflat = (np.floor(X / h).astype(np.int64) % ng) * ng + (np.floor(Y / h).astype(np.int64) % ng)
    bead_lab = label.ravel()[gflat]
    nl = len(lumens)
    solvent = (types == W) | (types == N) | (types == KA) | (types == KB) | (types == Z)
    counts = np.zeros((nl, 7), np.int64)
    if nl:
        m = solvent & (bead_lab >= 0)
        np.add.at(counts, (bead_lab[m], types[m].astype(np.int64)), 1)
    area_px = np.bincount(label[label >= 0].ravel(), minlength=nl) if nl else np.zeros(0)

    # bulk outside medium and distance (through membrane) from each lumen boundary to it
    mlen = (int(np.sum(lipmask)) / nmol) if nmol else 4.0
    wall_max = 2.0 * mlen * 0.5 + c["wall_extra"]
    if nl:
        pts = np.zeros(ng * ng, bool)
        pts[gflat[lip_idx]] = True
        memb_all = _dilate_periodic(pts.reshape(ng, ng), offs)
        del pts
        outside = _bulk_outside(memb_all)
        del memb_all
        out_any = bool(outside.any())
        Mpx = int(np.ceil(wall_max / h)) + 2
    # aqueous + exposure tests
    keep = []
    for k, lu in enumerate(lumens):
        area = area_px[k] * h * h
        hyd = counts[k, W] + counts[k, N] + counts[k, KA] + counts[k, KB]
        lu["area"] = area
        g = lu["gpix"] % ng
        isb = _boundary(g, label, k, ng)
        gbu = lu["gpix"][isb] if isb.any() else lu["gpix"]
        dob = (_dist_window(outside, gbu, ng, Mpx) * h) if out_any else np.full(len(gbu), np.inf)
        # a lumen that is itself (part of) the bulk medium is not a compartment
        lu["is_bulk"] = bool(np.mean(outside[g[:, 0], g[:, 1]]) > 0.2)
        lu["exposure"] = 0.0 if lu["is_bulk"] else float(np.mean(dob <= wall_max))
        lu["wall"] = float(np.median(dob)) if np.isfinite(dob).any() else float("inf")
        lu["ok"] = ((area >= c["min_lumen_area"]) and (hyd >= c["min_aqueous_frac"] * c["rho"] * area)
                    and lu["exposure"] >= c["min_exposure"])
        if lu["ok"]:
            keep.append(k)
    if nl:
        del outside
    # relabel to kept lumens only
    newid = np.full(nl + 1, -1, ldt)
    for j, k in enumerate(keep):
        newid[k] = j
    label = newid[label] if nl else label   # -1 maps to newid[-1] = -1
    bead_lab = label.ravel()[gflat]
    del gflat
    lumens = [lumens[k] for k in keep]
    counts = counts[keep] if nl else counts
    ncell = len(lumens)

    # ---- assign lipids of each aggregate to nearest lumen of that aggregate
    # bead_cell: cell id of the lumen for solvent beads inside a lumen; for lipid beads that are
    # part of a cell wall: -(cell id) - 2  (so -1 = none, <= -2 = membrane of cell -v-2)
    bead_cell = np.full(nb, -1, np.int32)
    sm = solvent & (bead_lab >= 0)
    bead_cell[sm] = bead_lab[sm]
    del sm, bead_lab, solvent
    n_lip = np.zeros(ncell, np.int64)
    inner = np.zeros(ncell, np.int64)
    outer = np.zeros(ncell, np.int64)
    by_agg = {}
    for j, lu in enumerate(lumens):
        by_agg.setdefault(lu["agg"], []).append(j)
    for a, js in by_agg.items():
        # boundary pixels of each lumen (centres, periodic coords)
        bp, bl = [], []
        for j in js:
            g = lumens[j]["gpix"] % ng
            isb = _boundary(g, label, j, ng)
            gb = g[isb]
            if len(gb) == 0:
                gb = g
            bp.append((gb + 0.5) * h); bl.append(np.full(len(gb), j))
        bp = np.vstack(bp) % L; bl = np.concatenate(bl)
        tree = cKDTree(bp, boxsize=L)
        b0, b1 = np.searchsorted(sb, a), np.searchsorted(sb, a, "right")
        beads = order_b[b0:b1]
        mols_here = mol[beads]
        # a molecule belongs to the wall of the nearest lumen of its aggregate if its closest
        # bead lies within one membrane thickness (wall_max) of that lumen
        dist_b, nn_b = tree.query(P(beads))
        mm_b = mols_here
        order_m = np.lexsort((dist_b, mm_b))           # per molecule, closest bead first
        first = np.ones(len(order_m), bool)
        first[1:] = mm_b[order_m][1:] != mm_b[order_m][:-1]
        sel_b = order_m[first]
        mol_ids = mm_b[sel_b]
        mol_d = dist_b[sel_b]
        mol_c = bl[nn_b[sel_b]]
        ok = mol_d <= wall_max
        mol_cell = dict(zip(mol_ids[ok].tolist(), mol_c[ok].tolist()))
        cob = np.array([mol_cell.get(m, -1) for m in mols_here.tolist()])
        inw = cob >= 0
        bead_cell[beads[inw]] = -cob[inw] - 2
        np.add.at(n_lip, mol_c[ok], 1)
        heads = beads[(types[beads] == H) & inw]
        dist, nn = tree.query(P(heads)) if len(heads) else (np.zeros(0), np.zeros(0, int))
        hl = bl[nn]
        np.add.at(inner, hl[dist <= c["leaflet_in"]], 1)
        np.add.at(outer, hl[(dist > c["leaflet_in"]) & (dist <= c["leaflet_max"])], 1)

    # bilayer test on the wall (needs the leaflet counts above)
    lo_if, hi_if = c["inner_frac_range"]
    bil_ok = []
    for j in range(len(lumens)):
        tot = inner[j] + outer[j]
        f_in = inner[j] / max(tot, 1)
        bil_ok.append(tot >= 6 and lo_if <= f_in <= hi_if)
    cells = []
    for j, lu in enumerate(lumens):
        gp = lu["gpix"].astype(np.float64)
        Pp = (gp + 0.5) * h                        # unwrapped lumen pixel centres
        cen = Pp.mean(0)
        cov = np.cov(Pp.T) if len(Pp) > 2 else np.eye(2)
        ev = np.sort(np.linalg.eigvalsh(cov))
        aspect = float(np.sqrt(ev[1] / max(ev[0], 1e-9)))
        try:
            hull = ConvexHull(Pp)
            solidity = float(len(Pp) * h * h / max(hull.volume, 1e-9))
        except (QhullError, ValueError):
            solidity = 1.0
        area = float(lu["area"])
        cells.append(dict(
            id=j,
            x=float(cen[0] % L), y=float(cen[1] % L),
            area=round(area, 3),
            r_eq=round(float(np.sqrt(area / np.pi)), 3),
            n_lipids=int(n_lip[j]),                  # wall lipids: within wall_max of this lumen
            n_Ka=int(counts[j, KA]), n_Kb=int(counts[j, KB]),
            n_N=int(counts[j, N]), n_W=int(counts[j, W]), n_Z=int(counts[j, Z]),
            agg=int(lu["agg"]),
            agg_lumens=len(by_agg[lu["agg"]]),
            agg_lipids=int(agg_size[lu["agg"]]),     # whole membrane aggregate (may be a network)
            inner_heads=int(inner[j]), outer_heads=int(outer[j]),
            inner_frac=round(float(inner[j] / max(inner[j] + outer[j], 1)), 3),
            aspect=round(aspect, 3), solidity=round(min(solidity, 1.0), 3),
            extent=round(float(np.sqrt(ev[1]) * 4), 2),
            wraps_membrane=bool(lu["wraps_agg"]),
            exposure=round(lu["exposure"], 3), wall=round(lu["wall"], 2) if np.isfinite(lu["wall"]) else None,
        ))
    # drop lumens whose wall is not bilayer-like; relabel grid, bead map and ids consistently
    if cells and not all(bil_ok):
        keep_ids = [j for j in range(len(cells)) if bil_ok[j]]
        m = np.full(len(cells) + 1, -1, label.dtype)
        m[keep_ids] = np.arange(len(keep_ids))
        label = m[label]
        m = m.astype(np.int32)
        bc = bead_cell
        lum = bc >= 0
        mem = bc <= -2
        nb_ = np.full(len(bc), -1, np.int32)
        nb_[lum] = m[bc[lum]]
        mm = m[-bc[mem] - 2]
        nb_[mem] = np.where(mm >= 0, -mm - 2, -1)
        bead_cell = nb_
        cells = [cells[j] for j in keep_ids]
        for k, cl in enumerate(cells):
            cl["id"] = k
    n_free = int(np.sum(agg_size[agg_of_mol] < c["min_membrane_lipids"])) if nmol else 0
    summary = dict(n_molecules=int(nmol), n_aggregates=int(nagg),
                   n_membranes=int(len(cand_aggs)), lipids_in_small_aggregates=n_free,
                   largest_aggregate=int(agg_size.max()) if nmol else 0,
                   wrapping_membranes=int(sum(a["wraps"] for a in agg_info)))
    ldt = np.int16 if len(cells) < INT16_LABELS else np.int32
    return dict(cells=cells, label=label.astype(ldt, copy=False), bead_cell=bead_cell, h=h, ng=ng,
                aggregates=agg_info, summary=summary, mol=mol, bead_agg=bead_agg)
