"""Fluorescence 'confocal micrograph' rendering of a snapshot (SPEC section 8.1).

Physics-flavoured image formation:
  * every fluorophore bead is deposited (bilinear) on a fine grid and convolved with a PSF
    (sharp Gaussian core + weak wide halo = out-of-focus light), exactly periodic for whole-box
    views (FFT), windowed with a margin otherwise
  * membrane dye (FM 4-64-like) only lights up in a hydrophobic environment: tail/head beads are
    weighted by how many tail beads surround them, so free lipids are dim and bilayers bright
  * catalysts Ka / Kb are GFP / YFP-like puncta, nutrients a faint blue haze (wide blur)
  * detector: photon shot noise (Poisson) per channel, read noise, dark offset, vignetting
  * display: per-channel lookup (soft saturation), additive merge, gamma
"""
import numpy as np
from scipy import fft as sfft
from scipy.spatial import cKDTree
from PIL import Image

import ocio
import style
from ocio import H, T, N, KA, KB, Z

# linear-light colours of the channels (merged like a multichannel confocal image)
COLORS = {
    "memb": np.array([1.00, 0.05, 0.24]),   # FM 4-64: red-magenta
    "ka": np.array([0.22, 1.00, 0.30]),     # GFP
    "kb": np.array([0.78, 1.00, 0.10]),     # YFP
    "nut": np.array([0.16, 0.32, 1.00]),    # faint blue haze
    "z": np.array([0.15, 0.75, 1.00]),      # CFP (fallback division ring)
}
LEGEND = {
    "memb": "membraan · FM 4-64",
    "ka": "katalysator a · GFP",
    "kb": "katalysator b · YFP",
    "nut": "voedingsstof",
    "z": "Z-ring · CFP",
}

DEFAULT = dict(
    psf=0.65,          # PSF core sigma (sim units)
    w_head=0.18,       # dye weight of head beads / inner tail beads (chain ends = 1)
    w_tail=0.45,
    halo=2.4,          # out-of-focus halo sigma
    halo_w=0.07,       # fraction of light in the halo
    nut_sigma=2.0,     # nutrients: blurred haze
    gain=dict(memb=0.78, ka=0.62, kb=0.62, nut=0.028, z=0.6),
    photons=dict(memb=70.0, ka=45.0, kb=45.0, nut=600.0, z=45.0),  # photons at value 1
    dye_shape=dict(memb=2.2, ka=9.0, kb=9.0, z=9.0),   # gamma-distributed brightness per bead
    read_noise=0.0045,
    dark=0.0015,
    vignette=0.22,
    gamma=1 / 1.45,
    seed=7,
)


def _tail_weight(pos_q, tpos, L, r=1.2, full=6.0, floor=0.10):
    """Environment weight: number of tail beads within r of each query (dye brightness)."""
    if len(tpos) == 0 or len(pos_q) == 0:
        return np.zeros(len(pos_q))
    tree = cKDTree(tpos, boxsize=L)
    n = tree.query_ball_point(pos_q, r, return_length=True).astype(float)
    return np.clip((n - 1.0) / full, floor, 1.0)


def _deposit(gx, gy, w, ny, nx, periodic):
    """Bilinear (cloud-in-cell) deposit of weights w at pixel coords (gx, gy) -> (ny, nx)."""
    x0 = np.floor(gx).astype(np.int64); y0 = np.floor(gy).astype(np.int64)
    fx = gx - x0; fy = gy - y0
    out = np.zeros(ny * nx, np.float64)
    for dx, dy, ww in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        xi = x0 + dx; yi = y0 + dy
        if periodic:
            xi %= nx; yi %= ny; m = slice(None)
            idx = yi * nx + xi; wt = w * ww
        else:
            m = (xi >= 0) & (xi < nx) & (yi >= 0) & (yi < ny)
            idx = yi[m] * nx + xi[m]; wt = (w * ww)[m]
        out += np.bincount(idx, weights=wt, minlength=ny * nx)
    return out.reshape(ny, nx)


def _blur(grids, sigmas_px, weights):
    """FFT convolution of each grid with sum_i weights[i] * Gaussian(sigmas_px[i]) (periodic)."""
    ny, nx = grids[0].shape
    ky = sfft.fftfreq(ny)[:, None]; kx = sfft.rfftfreq(nx)[None, :]
    k2 = kx * kx + ky * ky
    out = []
    for g, sig, wts in zip(grids, sigmas_px, weights):
        F = sfft.rfft2(g, workers=2)
        Tf = sum(wi * np.exp(-2 * np.pi ** 2 * s * s * k2) for s, wi in zip(sig, wts))
        out.append(sfft.irfft2(F * Tf, s=(ny, nx), workers=2))
    return out


def full_view(L):
    return (0.0, 0.0, L, L)


def cell_view(L, cx, cy, size):
    return (cx - size / 2, cy - size / 2, size, size)


def channel_images(snap, view, width, height, prm, ss=1):
    """Blurred channel intensities (float arrays, height*ss x width*ss), normalised so that
    1.0 = a typical bright bilayer (memb) / one isolated catalyst (ka, kb, z) / bulk nutrient
    concentration (nut)."""
    L = snap.L
    x0, y0, w, h = view
    W = width * ss; Hh = height * ss
    ppu = W / w
    periodic = abs(w - L) < 1e-6 and abs(h - L) < 1e-6
    margin = 0.0 if periodic else 4.0 * max(prm["halo"], prm["nut_sigma"])
    mp = int(np.ceil(margin * ppu))
    nx, ny = W + 2 * mp, Hh + 2 * mp
    pos = np.stack([snap.x, snap.y], 1)
    t = snap.type
    tpos = pos[t == T]

    sel = {
        "memb": (t == H) | (t == T),
        "ka": t == KA, "kb": t == KB, "nut": t == N, "z": t == Z,
    }
    grids, sig, wts, names = [], [], [], []
    for name, m in sel.items():
        if not m.any() and name not in ("memb",):
            continue
        p = pos[m]
        if name == "memb":
            # the dye sits in the hydrophobic core: chain-end tail beads (one bond, at the bilayer
            # midplane) brightest, inner tail beads less, heads dim -> crisp membrane line
            wgt = _tail_weight(p, tpos, L)
            deg = np.bincount(snap.bonds.ravel(), minlength=len(t))[m] if len(snap.bonds) else np.ones(len(p))
            tt = t[m]
            wgt *= np.where(tt == H, prm["w_head"], np.where(deg <= 1, 1.0, prm["w_tail"]))
        else:
            wgt = np.ones(len(p))
        if name in prm["dye_shape"]:
            # stochastic labelling / brightness per molecule; fixed per bead id (stable in video)
            k = prm["dye_shape"][name]
            dye = np.random.default_rng(prm["seed"] + 101).gamma(k, 1.0 / k, len(t))
            wgt = wgt * dye[m]
        # periodic images that fall inside the (margin-extended) window
        gxs, gys, ws = [], [], []
        ox = x0 - margin; oy = y0 - margin
        dx = np.mod(p[:, 0] - ox, L); dy = np.mod(p[:, 1] - oy, L)
        spanx = w + 2 * margin; spany = h + 2 * margin
        for kx in range(int(np.ceil(spanx / L)) + 1):
            for ky in range(int(np.ceil(spany / L)) + 1):
                xx = dx + kx * L; yy = dy + ky * L
                mm = (xx < spanx + 1 / ppu) & (yy < spany + 1 / ppu)
                if periodic and (kx or ky):
                    continue
                gxs.append(xx[mm]); gys.append(yy[mm]); ws.append(wgt[mm])
        gx = np.concatenate(gxs) * ppu - 0.5
        gy = (spany - np.concatenate(gys)) * ppu - 0.5     # row 0 = top (y up)
        grids.append(_deposit(gx, gy, np.concatenate(ws), ny, nx, periodic))
        if name == "nut":
            sig.append([prm["nut_sigma"] * ppu]); wts.append([1.0])
        else:
            sig.append([prm["psf"] * ppu, prm["halo"] * ppu]); wts.append([1 - prm["halo_w"], prm["halo_w"]])
        names.append(name)
    blurred = _blur(grids, sig, wts) if grids else []
    out = {}
    for name, g in zip(names, blurred):
        g = g[mp:mp + Hh, mp:mp + W] if mp else g
        if name in ("ka", "kb", "z"):
            g = g * (2 * np.pi * (prm["psf"] * ppu) ** 2) / (1 - prm["halo_w"])   # one bead -> 1
        elif name == "nut":
            g = g * ppu * ppu / (3.0 * 0.08)                                       # bulk c_N -> ~1
        else:
            g = g * ppu * ppu / 1.3                                                 # bilayer core -> ~1
        out[name] = np.maximum(g, 0).astype(np.float32)
    return out


def _pool(a, f):
    if f == 1:
        return a
    H, W = a.shape
    return a[:H - H % f, :W - W % f].reshape(H // f, f, W // f, f).mean(axis=(1, 3))


def compose(chans, prm, norm=None, rng=None, ss=1):
    """Detector noise + display mapping -> linear RGB float image in [0,1] (before gamma)."""
    rng = rng if rng is not None else np.random.default_rng(prm["seed"])
    norm = norm or {}
    rgb = None
    for name, g in chans.items():
        g = _pool(g, ss)
        g = g / norm.get(name, 1.0)
        ph = prm["photons"][name]
        noisy = rng.poisson(np.clip(g, 0, 50) * ph).astype(np.float32) / ph
        noisy += rng.normal(0, prm["read_noise"], g.shape).astype(np.float32)
        v = prm["gain"][name] * noisy
        # display lookup: linear with a soft knee near the top (no hard clipping of bright puncta)
        v = np.where(v < 0.8, v, 0.8 + 0.2 * (1 - np.exp(-(v - 0.8) / 0.2)))
        c = COLORS[name][None, None, :] * v[..., None]
        rgb = c if rgb is None else rgb + c
    if rgb is None:
        raise ValueError("no fluorescent beads in view")
    Hh, W = rgb.shape[:2]
    rgb += prm["dark"] * np.array([0.85, 0.9, 1.0])
    # vignetting
    yy, xx = np.mgrid[0:Hh, 0:W]
    r2 = ((xx - W / 2) ** 2 + (yy - Hh / 2) ** 2) / ((W / 2) ** 2 + (Hh / 2) ** 2)
    rgb *= (1 - prm["vignette"] * r2 ** 1.1)[..., None]
    # merged colours: clip with a knee, then display gamma
    rgb = np.maximum(rgb, 0)
    rgb = np.where(rgb < 0.85, rgb, 0.85 + 0.15 * (1 - np.exp(-(rgb - 0.85) / 0.15)))
    return np.clip(rgb, 0, 1) ** prm["gamma"]


def auto_norm(chans):
    """Normalisation from the data: membrane 99.7th percentile of lit pixels -> ~1."""
    n = {}
    m = chans.get("memb")
    if m is not None:
        lit = m[m > 0.15 * m.max()] if m.max() > 0 else m
        n["memb"] = float(max(np.percentile(lit, 99.0), 1e-6)) if lit.size else 1.0
    return n


def render(snap, view=None, width=2000, height=None, ss=2, prm=None, norm=None, overlay=True,
           legend=True, title=None, seed=None):
    """Render a micrograph. Returns (PIL.Image RGB, info dict)."""
    p = dict(DEFAULT)
    if prm:
        p.update(prm)
    if seed is not None:
        p["seed"] = seed
    view = view or full_view(snap.L)
    height = height or int(round(width * view[3] / view[2]))
    chans = channel_images(snap, view, width, height, p, ss)
    nm = auto_norm(chans) if norm is None else norm
    rgb = compose(chans, p, nm, ss=ss)
    img = Image.fromarray((rgb * 255 + 0.5).astype(np.uint8), "RGB")
    ppu = width / view[2]
    if overlay:
        draw_overlay(img, ppu, snap, legend_channels=[c for c in chans if c != "nut"] if legend else [],
                     title=title)
    return img, dict(norm=nm, ppu=ppu, view=view)


def draw_overlay(img, ppu, snap, legend_channels=(), title=None, time_corner="tl"):
    W, H = img.size
    m = int(0.035 * W)
    f_big = style.font("Medium", int(0.026 * W))
    f_small = style.font("Regular", int(0.0165 * W))
    style.text_with_shadow(img, (m, m), style.fmt_time(snap.time), f_big, anchor="lt")
    style.text_with_shadow(img, (m, m + int(0.034 * W)), f"stap {ocio.fmt_int_nl(snap.step)}", f_small,
                           fill=(255, 255, 255, 190), anchor="lt")
    if title:
        style.text_with_shadow(img, (W - m, m), title, f_small, fill=(255, 255, 255, 210), anchor="rt")
    style.scale_bar(img, ppu, corner="br")
    y = H - m
    for name in reversed(list(legend_channels)):
        col = COLORS[name] / COLORS[name].max()
        col = tuple(int(255 * (0.35 + 0.65 * c) ** 0.6) for c in col) + (235,)
        style.text_with_shadow(img, (m, y), LEGEND[name], f_small, fill=col, anchor="ls")
        y -= int(0.026 * W)
    return img
