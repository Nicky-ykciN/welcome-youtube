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
     torus 'outside' means: touches the border of a 3x3 periodic tiling (non-contractible).
  5. a hole is a lumen (= cell) when its area >= min_lumen_area and it holds enough
     hydrophilic beads (W/N/K) to be aqueous.
  6. lipids of the aggregate are assigned to the nearest of its lumens; per-cell contents are
     counted on a global periodic label grid (smaller, nested lumens painted last).
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
    min_lumen_area=10.0,      # unit^2
    min_aqueous_frac=0.30,    # hydrophilic beads in lumen >= frac * rho * area
    rho=3.0,
    pad=2.5,                  # padding around an aggregate's bounding box (units)
    leaflet_in=1.5,           # head within this distance of the lumen = inner leaflet
    leaflet_max=6.0,          # heads further than this are not counted as wall heads
)

_S4 = ndimage.generate_binary_structure(2, 1)


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
    for i in order[1:].tolist():
        p = pr[i]
        ux[i] = ux[p] + Dx[i]; uy[i] = uy[p] + Dy[i]
    U = np.stack([np.array(ux), np.array(uy)], 1)
    du = U[edges[:, 1]] - U[edges[:, 0]]
    dm = minimg(pos[edges[:, 1]] - pos[edges[:, 0]], L)
    wraps = bool(np.any(np.abs(du - dm) > 0.5 * L))
    return U, wraps


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


def _holes_torus(gpix, ng, r_pix):
    """Enclosed (contractible) solvent regions of a membrane wrapping the periodic box.

    Returns list of unwrapped pixel coordinate arrays (k,2) (may be negative / > ng)."""
    pts = np.zeros((ng, ng), bool)
    pts[gpix[:, 0] % ng, gpix[:, 1] % ng] = True
    big = np.tile(pts, (3, 3))
    dist = ndimage.distance_transform_edt(~big)
    memb = dist <= r_pix
    lab, nl = ndimage.label(~memb, structure=_S4)
    if nl == 0:
        return []
    border = np.unique(np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]]))
    centre = lab[ng:2 * ng, ng:2 * ng]
    cand = np.setdiff1d(np.unique(centre), np.r_[0, border])
    out = []
    if len(cand) == 0:
        return out
    objs = ndimage.find_objects(lab)
    for l in cand.tolist():
        sl = objs[l - 1]
        sub = lab[sl] == l
        ii, jj = np.nonzero(sub)
        ii = ii + sl[0].start; jj = jj + sl[1].start
        ci, cj = ii.mean(), jj.mean()
        # keep only the copy whose centroid lies in the centre tile
        if ng <= ci < 2 * ng and ng <= cj < 2 * ng:
            out.append(np.stack([ii - ng, jj - ng], 1))
    return out


def detect(snap, cfg=None):
    """Detect cells in a Snapshot. Returns dict with 'cells' (list of dict), 'label' (ng x ng
    int16 global lumen label grid, -1 = none), 'bead_cell' (int32 per bead: c >= 0 solvent bead
    in the lumen of cell c; -c-2 lipid bead in the membrane of cell c; -1 otherwise), 'h', 'ng',
    'aggregates' (summary)."""
    c = dict(DEFAULTS)
    if cfg:
        c.update(cfg)
    L = snap.L
    ng = int(round(L / c["h"]))
    h = L / ng
    r_pix = c["r_stamp"] / h
    types = snap.type
    pos = np.stack([snap.x, snap.y], 1)
    nb = len(types)

    mol, nmol = lipid_molecules(types, snap.bonds)
    tidx = np.nonzero(types == T)[0]
    agg_of_mol = np.arange(nmol)
    pairs = np.zeros((0, 2), np.int64)
    if len(tidx) > 1 and nmol > 0:
        tree = cKDTree(pos[tidx], boxsize=L)
        pr = tree.query_pairs(c["r_tail"], output_type="ndarray")
        if len(pr):
            pairs = np.stack([tidx[pr[:, 0]], tidx[pr[:, 1]]], 1)
            mi, mj = mol[pairs[:, 0]], mol[pairs[:, 1]]
            g = coo_matrix((np.ones(len(mi)), (mi, mj)), shape=(nmol, nmol))
            _, agg_of_mol = connected_components(g, directed=False)
    nagg = int(agg_of_mol.max()) + 1 if nmol else 0
    agg_size = np.bincount(agg_of_mol, minlength=nagg) if nmol else np.zeros(0, int)
    bead_agg = np.full(nb, -1, np.int64)
    lipmask = mol >= 0
    bead_agg[lipmask] = agg_of_mol[mol[lipmask]]

    # bead-level edges inside lipids: bonds between lipid beads + tail contacts
    if len(snap.bonds):
        lb = snap.bonds[lipmask[snap.bonds[:, 0]] & lipmask[snap.bonds[:, 1]]]
    else:
        lb = np.zeros((0, 2), np.int64)
    all_edges = np.vstack([lb, pairs]) if len(pairs) else lb
    edge_agg = bead_agg[all_edges[:, 0]] if len(all_edges) else np.zeros(0, np.int64)

    cand_aggs = np.nonzero(agg_size >= c["min_membrane_lipids"])[0]
    # group beads and edges by aggregate
    order_b = np.argsort(bead_agg, kind="stable")
    sb = bead_agg[order_b]
    order_e = np.argsort(edge_agg, kind="stable")
    se = edge_agg[order_e]

    lumens = []   # dicts: agg, gpix (k,2) unwrapped global pixel coords, wraps
    agg_info = []
    for a in cand_aggs.tolist():
        b0, b1 = np.searchsorted(sb, a), np.searchsorted(sb, a, "right")
        beads = order_b[b0:b1]
        e0, e1 = np.searchsorted(se, a), np.searchsorted(se, a, "right")
        E = all_edges[order_e[e0:e1]]
        loc = np.full(nb, -1, np.int64)
        loc[beads] = np.arange(len(beads))
        El = loc[E]
        U, wraps = _unwrap_tree(pos[beads], len(beads), El, L)
        holes = []
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
                if ids:
                    objs = ndimage.find_objects(lab)
                    for l in ids:
                        sl = objs[l - 1]
                        ii, jj = np.nonzero(lab[sl] == l)
                        holes.append(np.stack([ii + sl[0].start + lo[0], jj + sl[1].start + lo[1]], 1))
        if wraps:
            gp = np.floor(pos[beads] / h).astype(np.int64)
            holes = _holes_torus(gp, ng, r_pix)
        agg_info.append(dict(agg=a, n_lipids=int(agg_size[a]), wraps=wraps, n_holes=len(holes)))
        for hp in holes:
            area = len(hp) * h * h
            if area >= c["min_lumen_area"]:
                lumens.append(dict(agg=a, gpix=hp, area_raw=area, wraps_agg=wraps))

    # ---- global label grid (largest first so nested lumens overwrite)
    lumens.sort(key=lambda d: -d["area_raw"])
    label = np.full((ng, ng), -1, np.int32)
    for k, lu in enumerate(lumens):
        gp = lu["gpix"] % ng
        label[gp[:, 0], gp[:, 1]] = k
    gi = np.floor(pos / h).astype(np.int64) % ng
    bead_lab = label[gi[:, 0], gi[:, 1]]
    nl = len(lumens)
    solvent = (types == W) | (types == N) | (types == KA) | (types == KB) | (types == Z)
    counts = np.zeros((nl, 7), np.int64)
    if nl:
        m = solvent & (bead_lab >= 0)
        np.add.at(counts, (bead_lab[m], types[m].astype(np.int64)), 1)
    area_px = np.bincount(label[label >= 0].ravel(), minlength=nl) if nl else np.zeros(0)

    # aqueous test
    keep = []
    for k, lu in enumerate(lumens):
        area = area_px[k] * h * h
        hyd = counts[k, W] + counts[k, N] + counts[k, KA] + counts[k, KB]
        lu["area"] = area
        lu["ok"] = (area >= c["min_lumen_area"]) and (hyd >= c["min_aqueous_frac"] * c["rho"] * area)
        if lu["ok"]:
            keep.append(k)
    # relabel to kept lumens only
    newid = np.full(nl + 1, -1, np.int32)
    for j, k in enumerate(keep):
        newid[k] = j
    label = newid[label] if nl else label   # -1 maps to newid[-1] = -1
    bead_lab = label[gi[:, 0], gi[:, 1]]
    lumens = [lumens[k] for k in keep]
    counts = counts[keep] if nl else counts
    ncell = len(lumens)

    # ---- assign lipids of each aggregate to nearest lumen of that aggregate
    # bead_cell: cell id of the lumen for solvent beads inside a lumen; for lipid beads that are
    # part of a cell wall: -(cell id) - 2  (so -1 = none, <= -2 = membrane of cell -v-2)
    bead_cell = np.full(nb, -1, np.int32)
    sm = solvent & (bead_lab >= 0)
    bead_cell[sm] = bead_lab[sm]
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
            # boundary: pixels with a 4-neighbour outside the lumen
            g = lumens[j]["gpix"] % ng
            nbrs = [((g + d) % ng) for d in ((1, 0), (-1, 0), (0, 1), (0, -1))]
            isb = np.zeros(len(g), bool)
            for nbx in nbrs:
                isb |= label[nbx[:, 0], nbx[:, 1]] != j
            gb = g[isb]
            if len(gb) == 0:
                gb = g
            bp.append((gb + 0.5) * h); bl.append(np.full(len(gb), j))
        bp = np.vstack(bp) % L; bl = np.concatenate(bl)
        tree = cKDTree(bp, boxsize=L)
        b0, b1 = np.searchsorted(sb, a), np.searchsorted(sb, a, "right")
        beads = order_b[b0:b1]
        mols_here = mol[beads]
        # one representative per molecule: its head bead (or first bead)
        heads = beads[types[beads] == H]
        dist, nn = tree.query(pos[heads])
        hl = bl[nn]
        # molecule -> cell via its head; molecules without head use their first bead
        mol_cell = {}
        for mm, cc in zip(mol[heads].tolist(), hl.tolist()):
            mol_cell[mm] = cc
        missing = [b for b in beads.tolist() if mol[b] not in mol_cell]
        if missing:
            d2, nn2 = tree.query(pos[missing])
            for b, cc in zip(missing, bl[nn2].tolist()):
                mol_cell.setdefault(int(mol[b]), cc)
        cell_of_bead = np.array([mol_cell[m] for m in mols_here.tolist()])
        bead_cell[beads] = -cell_of_bead - 2
        for mm, cc in mol_cell.items():
            n_lip[cc] += 1
        np.add.at(inner, hl[dist <= c["leaflet_in"]], 1)
        np.add.at(outer, hl[(dist > c["leaflet_in"]) & (dist <= c["leaflet_max"])], 1)

    cells = []
    for j, lu in enumerate(lumens):
        gp = lu["gpix"].astype(np.float64)
        P = (gp + 0.5) * h                         # unwrapped lumen pixel centres
        cen = P.mean(0)
        cov = np.cov(P.T) if len(P) > 2 else np.eye(2)
        ev = np.sort(np.linalg.eigvalsh(cov))
        aspect = float(np.sqrt(ev[1] / max(ev[0], 1e-9)))
        try:
            hull = ConvexHull(P)
            solidity = float(len(P) * h * h / max(hull.volume, 1e-9))
        except (QhullError, ValueError):
            solidity = 1.0
        area = float(lu["area"])
        cells.append(dict(
            id=j,
            x=float(cen[0] % L), y=float(cen[1] % L),
            area=round(area, 3),
            r_eq=round(float(np.sqrt(area / np.pi)), 3),
            n_lipids=int(n_lip[j]),
            n_Ka=int(counts[j, KA]), n_Kb=int(counts[j, KB]),
            n_N=int(counts[j, N]), n_W=int(counts[j, W]), n_Z=int(counts[j, Z]),
            agg=int(lu["agg"]),
            agg_lumens=len(by_agg[lu["agg"]]),
            agg_lipids=int(agg_size[lu["agg"]]),
            inner_heads=int(inner[j]), outer_heads=int(outer[j]),
            inner_frac=round(float(inner[j] / max(inner[j] + outer[j], 1)), 3),
            aspect=round(aspect, 3), solidity=round(min(solidity, 1.0), 3),
            extent=round(float(np.sqrt(ev[1]) * 4), 2),
            wraps_membrane=bool(lu["wraps_agg"]),
        ))
    n_free = int(np.sum(agg_size[agg_of_mol] < c["min_membrane_lipids"])) if nmol else 0
    summary = dict(n_molecules=int(nmol), n_aggregates=int(nagg),
                   n_membranes=int(len(cand_aggs)), lipids_in_small_aggregates=n_free,
                   largest_aggregate=int(agg_size.max()) if nmol else 0,
                   wrapping_membranes=int(sum(a["wraps"] for a in agg_info)))
    return dict(cells=cells, label=label.astype(np.int16), bead_cell=bead_cell, h=h, ng=ng,
                aggregates=agg_info, summary=summary, mol=mol, bead_agg=bead_agg)
