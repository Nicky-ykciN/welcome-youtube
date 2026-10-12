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

Large boxes (L = 1024 - 2048, up to 12.6 M beads): zoomed views only process the beads near the
view (the result is the same as with all beads); channels are blurred one at a time; above
BIG_GRID pixels the FFT and the display maths run in float32 and supersampling is dropped when the
PSF already spans >= 1 output pixel.  Images of normal size are bit-identical to before.
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

BIG_GRID = 20_000_000      # pixels; larger grids are processed in float32 (memory)
SS_LIMIT = 36_000_000      # supersampled pixels above which ss is reduced to 1 (if the PSF allows)


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
    """FFT convolution of each grid with sum_i weights[i] * Gaussian(sigmas_px[i]) (periodic).
    float32 grids are transformed in single precision (half the memory)."""
    ny, nx = grids[0].shape
    ky = sfft.fftfreq(ny)[:, None]; kx = sfft.rfftfreq(nx)[None, :]
    k2 = kx * kx + ky * ky
    if grids[0].dtype == np.float32:
        k2 = k2.astype(np.float32)
    out = []
    for g, sig, wts in zip(grids, sigmas_px, weights):
        F = sfft.rfft2(g, workers=2)
        Tf = sum(wi * np.exp(-2 * np.pi ** 2 * s * s * k2) for s, wi in zip(sig, wts))
        F *= Tf
        del Tf
        out.append(sfft.irfft2(F, s=(ny, nx), workers=2))
        del F
    return out


def full_view(L):
    return (0.0, 0.0, L, L)


def cell_view(L, cx, cy, size):
    return (cx - size / 2, cy - size / 2, size, size)


def _window_mask(x, y, L, ox, oy, spanx, spany):
    """Beads whose periodic image lies in [ox, ox + spanx) x [oy, oy + spany) (None = all)."""
    if spanx >= L and spany >= L:
        return None
    return (np.mod(x - ox, L) < spanx) & (np.mod(y - oy, L) < spany)


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
    big = nx * ny > BIG_GRID
    X = snap.x; Y = snap.y
    t = snap.type
    ox = x0 - margin; oy = y0 - margin
    spanx = w + 2 * margin; spany = h + 2 * margin
    # beads that can reach the (margin-extended) window; for a zoomed view of a big box this is a
    # small fraction - the per-bead work below is then done for those beads only (same result)
    eps = 2.0 / ppu
    near = _window_mask(X, Y, L, ox - eps, oy - eps, spanx + 2 * eps, spany + 2 * eps)
    r_env = 1.2                                       # tail neighbourhood of the membrane dye
    near_t = _window_mask(X, Y, L, ox - eps - r_env, oy - eps - r_env, spanx + 2 * (eps + r_env),
                          spany + 2 * (eps + r_env))
    tm = t == T
    tpos = np.stack([X[tm], Y[tm]], 1) if near_t is None else np.stack([X[tm & near_t], Y[tm & near_t]], 1)

    sel = {
        "memb": (t == H) | (t == T),
        "ka": t == KA, "kb": t == KB, "nut": t == N, "z": t == Z,
    }
    deg_all = None
    dyes = {}
    out = {}
    for name, m in sel.items():
        if not m.any() and name not in ("memb",):
            continue
        mm_ = m if near is None else (m & near)
        p = np.stack([X[mm_], Y[mm_]], 1)
        if name == "memb":
            # the dye sits in the hydrophobic core: chain-end tail beads (one bond, at the bilayer
            # midplane) brightest, inner tail beads less, heads dim -> crisp membrane line
            wgt = _tail_weight(p, tpos, L)
            if len(snap.bonds):
                if deg_all is None:
                    deg_all = np.bincount(snap.bonds.ravel(), minlength=len(t))
                deg = deg_all[mm_]
            else:
                deg = np.ones(len(p))
            tt = t[mm_]
            wgt *= np.where(tt == H, prm["w_head"], np.where(deg <= 1, 1.0, prm["w_tail"]))
        else:
            wgt = np.ones(len(p))
        if name in prm["dye_shape"]:
            # stochastic labelling / brightness per molecule; fixed per bead id (stable in video)
            k = prm["dye_shape"][name]
            if k not in dyes:
                dyes[k] = np.random.default_rng(prm["seed"] + 101).gamma(k, 1.0 / k, len(t))
            wgt = wgt * dyes[k][mm_]
        # periodic images that fall inside the (margin-extended) window
        gxs, gys, ws = [], [], []
        dx = np.mod(p[:, 0] - ox, L); dy = np.mod(p[:, 1] - oy, L)
        for kx in range(int(np.ceil(spanx / L)) + 1):
            for ky in range(int(np.ceil(spany / L)) + 1):
                xx = dx + kx * L; yy = dy + ky * L
                mm = (xx < spanx + 1 / ppu) & (yy < spany + 1 / ppu)
                if periodic and (kx or ky):
                    continue
                gxs.append(xx[mm]); gys.append(yy[mm]); ws.append(wgt[mm])
        del p, dx, dy, wgt
        gx = np.concatenate(gxs) * ppu - 0.5
        gy = (spany - np.concatenate(gys)) * ppu - 0.5     # row 0 = top (y up)
        grid = _deposit(gx, gy, np.concatenate(ws), ny, nx, periodic)
        del gx, gy, gxs, gys, ws
        if big:
            grid = grid.astype(np.float32)
        if name == "nut":
            sig = [prm["nut_sigma"] * ppu]; wts = [1.0]
        else:
            sig = [prm["psf"] * ppu, prm["halo"] * ppu]; wts = [1 - prm["halo_w"], prm["halo_w"]]
        g = _blur([grid], [sig], [wts])[0]
        del grid
        g = g[mp:mp + Hh, mp:mp + W] if mp else g
        if name in ("ka", "kb", "z"):
            g = g * (2 * np.pi * (prm["psf"] * ppu) ** 2) / (1 - prm["halo_w"])   # one bead -> 1
        elif name == "nut":
            g = g * ppu * ppu / (3.0 * 0.08)                                       # bulk c_N -> ~1
        else:
            g = g * ppu * ppu / 1.3                                                 # bilayer core -> ~1
        out[name] = np.maximum(g, 0).astype(np.float32)
        del g
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
    first = next(iter(chans.values()), None)
    if first is None:
        raise ValueError("no fluorescent beads in view")
    Hh, W = first.shape[0] // ss, first.shape[1] // ss
    if Hh * W * 3 > BIG_GRID:
        return _compose_lean(chans, prm, norm, rng, ss)
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
    Hh, W = rgb.shape[:2]
    rgb += prm["dark"] * np.array([0.85, 0.9, 1.0])
    # vignetting (open grids: same numbers as a full mgrid, a fraction of the memory)
    yy, xx = np.ogrid[0:Hh, 0:W]
    r2 = ((xx - W / 2) ** 2 + (yy - Hh / 2) ** 2) / ((W / 2) ** 2 + (Hh / 2) ** 2)
    rgb *= (1 - prm["vignette"] * r2 ** 1.1)[..., None]
    # merged colours: clip with a knee, then display gamma
    rgb = np.maximum(rgb, 0)
    rgb = np.where(rgb < 0.85, rgb, 0.85 + 0.15 * (1 - np.exp(-(rgb - 0.85) / 0.15)))
    return np.clip(rgb, 0, 1) ** prm["gamma"]


def _knee(v, k, s):
    """In place: v < k unchanged, above it k + s (1 - exp(-(v - k) / s))."""
    hi = v >= k
    v[hi] = k + s * (1 - np.exp(-(v[hi] - k) / s))
    return v


def _compose_lean(chans, prm, norm, rng, ss):
    """compose() for very large images: same model, float32 and in-place operations (about
    40 bytes per output pixel instead of ~150)."""
    rgb = None
    for name, g in chans.items():
        g = _pool(g, ss).astype(np.float32, copy=False)
        g = g / np.float32(norm.get(name, 1.0))
        ph = prm["photons"][name]
        np.clip(g, 0, 50, out=g)
        g *= np.float32(ph)
        noisy = rng.poisson(g).astype(np.float32)
        del g
        noisy /= np.float32(ph)
        noisy += np.float32(prm["read_noise"]) * rng.standard_normal(noisy.shape, dtype=np.float32)
        noisy *= np.float32(prm["gain"][name])
        v = _knee(noisy, 0.8, 0.2)
        if rgb is None:
            rgb = np.zeros(v.shape + (3,), np.float32)
        for ch in range(3):
            rgb[..., ch] += np.float32(COLORS[name][ch]) * v
        del v, noisy
    Hh, W = rgb.shape[:2]
    yy, xx = np.ogrid[0:Hh, 0:W]
    r2 = ((xx - W / 2) ** 2 + (yy - Hh / 2) ** 2) / ((W / 2) ** 2 + (Hh / 2) ** 2)
    vig = (1 - prm["vignette"] * r2 ** 1.1).astype(np.float32)
    del r2
    dark = prm["dark"] * np.array([0.85, 0.9, 1.0])
    for ch in range(3):
        c = rgb[..., ch]
        c += np.float32(dark[ch])
        c *= vig
        np.maximum(c, 0, out=c)
        _knee(c, 0.85, 0.15)
        np.clip(c, 0, 1, out=c)
        np.power(c, np.float32(prm["gamma"]), out=c)
    return rgb


def auto_norm(chans):
    """'Exposure' from the data, like a microscopist setting the gain per channel.

    membrane: 99th percentile of lit pixels -> 1.  catalysts (one shared setting for GFP and YFP so
    their brightness stays comparable): a single isolated molecule = 1, unless dense clusters would
    saturate - then the gain is lowered so the 99.7th percentile of lit pixels maps to ~1.3."""
    n = {}
    m = chans.get("memb")
    if m is not None:
        lit = m[m > 0.15 * m.max()] if m.max() > 0 else m
        n["memb"] = float(max(np.percentile(lit, 99.0), 1e-6)) if lit.size else 1.0
    ks = [chans[k] for k in ("ka", "kb") if k in chans]
    if ks:
        k = ks[0] if len(ks) == 1 else ks[0] + ks[1]
        lit = k[k > 0.2]
        kn = float(np.percentile(lit, 99.7)) / 1.3 if lit.size > 50 else 1.0
        n["ka"] = n["kb"] = kn if kn > 1.5 else 1.0
    if "z" in chans:
        z = chans["z"]; lit = z[z > 0.2]
        n["z"] = max(1.0, float(np.percentile(lit, 99.7)) / 1.3) if lit.size > 50 else 1.0
    return n


def effective_ss(width, height, view, ss, prm):
    """Supersampling factor actually used: 1 instead of ss for very large images when the PSF
    core already spans >= 1 output pixel (no aliasing; saves ss^2 memory and time)."""
    if ss > 1 and width * height * ss * ss > SS_LIMIT and prm["psf"] * width / view[2] >= 1.0:
        return 1
    return ss


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
    ss = effective_ss(width, height, view, ss, p)
    chans = channel_images(snap, view, width, height, p, ss)
    nm = auto_norm(chans) if norm is None else norm
    rgb = compose(chans, p, nm, ss=ss)
    channels = list(chans)
    del chans
    if rgb.dtype == np.float32:
        rgb *= np.float32(255); rgb += np.float32(0.5)
        img = Image.fromarray(rgb.astype(np.uint8), "RGB")
    else:
        img = Image.fromarray((rgb * 255 + 0.5).astype(np.uint8), "RGB")
    del rgb
    ppu = width / view[2]
    if overlay:
        draw_overlay(img, ppu, snap, legend_channels=[c for c in channels if c != "nut"] if legend else [],
                     title=title)
    return img, dict(norm=nm, ppu=ppu, view=view)


def draw_overlay(img, ppu, snap, legend_channels=(), title=None, time_corner="tl"):
    W, H = img.size
    m = int(0.035 * W)
    f_big = style.font("Medium", max(18, int(0.026 * W)))
    f_small = style.font("Regular", max(13, int(0.0165 * W)))
    style.text_with_shadow(img, (m, m), style.fmt_time(snap.time), f_big, anchor="lt")
    style.text_with_shadow(img, (m, m + int(1.3 * f_big.size)), f"stap {ocio.fmt_int_nl(snap.step)}", f_small,
                           fill=(255, 255, 255, 190), anchor="lt")
    if title:
        style.text_with_shadow(img, (W - m, m), title, f_small, fill=(255, 255, 255, 210), anchor="rt")
    style.scale_bar(img, ppu, corner="br")
    y = H - m
    for name in reversed(list(legend_channels)):
        col = COLORS[name] / COLORS[name].max()
        col = tuple(int(255 * (0.35 + 0.65 * c) ** 0.6) for c in col) + (235,)
        style.text_with_shadow(img, (m, y), LEGEND[name], f_small, fill=col, anchor="ls")
        y -= int(1.55 * f_small.size)
    return img
