"""Molecular illustration of one cell in the watercolour style of David Goodsell (SPEC 8.2).

Every bead is drawn at its simulated position (nothing invented): lipid heads as ink-outlined
circles, the hydrophobic tails as a pale band with one short stroke per tail, catalysts as larger
soft lobed blobs, nutrients as small outlined circles, water omitted.  Washes: warm inside the
lumen (from the cell detection), cool outside, with pigment pooling at the wash edges, paper
grain and an irregular watercolour vignette.  Drawn 3x supersampled, Lanczos-downsampled.
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

import ocio
import style
from ocio import H, T, N, KA, KB, Z


def hexc(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], float)


PAL = dict(
    paper=hexc("#F4EEE2"),
    outside=hexc("#D9E8E6"),
    lumen=hexc("#F6DFBC"),
    head=hexc("#E2976A"), head_ink=hexc("#6A2E1E"),
    tail=hexc("#F1D88F"), tail_ink=hexc("#A8833C"), tail_line=hexc("#C49B4C"),
    ka=hexc("#8CC38C"), ka_ink=hexc("#2E6236"),
    kb=hexc("#CCD86A"), kb_ink=hexc("#66711C"),
    nut=hexc("#C3CBE6"), nut_ink=hexc("#7782AE"),
    z=hexc("#EE8E86"), z_ink=hexc("#863832"),
    ink=hexc("#3B2F2A"),
)

SIZES = dict(head_r=0.37, ink=0.065, tail_w=0.62, tail_line=0.085, nut_r=0.24, cat_r=1.15, z_r=0.36)


def _c(rgb, jitter=0.0, rng=None):
    v = np.array(rgb, float)
    if jitter and rng is not None:
        v = v * (1 + rng.normal(0, jitter)) + rng.normal(0, jitter * 40, 3)
    return tuple(int(x) for x in np.clip(v, 0, 255))


def _noise(shape, scale, rng, octaves=3):
    """Smooth value noise in [-1, 1] approx, feature size `scale` pixels."""
    H, W = shape
    out = np.zeros(shape, np.float32)
    amp = 1.0; tot = 0
    for o in range(octaves):
        s = max(2, int(scale / (2 ** o)))
        small = rng.normal(0, 1, (H // s + 3, W // s + 3)).astype(np.float32)
        big = np.array(Image.fromarray(small, "F").resize((small.shape[1] * s, small.shape[0] * s), Image.BICUBIC))
        out += amp * big[:H, :W]
        tot += amp; amp *= 0.5
    return out / tot


def protein_lobes(c, r0, ident):
    """Irregular globular protein outline: overlapping circles, fixed per bead id."""
    lr = np.random.default_rng(ident * 7919 + 17)
    lobes = []
    nl = int(lr.integers(6, 10))
    for k in range(nl):
        a = lr.uniform(0, 2 * np.pi)
        rr = r0 * lr.uniform(0.30, 0.48)
        off = (r0 - rr) * lr.uniform(0.55, 1.0)
        lobes.append((c[0] + off * np.cos(a), c[1] + off * np.sin(a), rr))
    lobes.sort(key=lambda l: (l[0] - c[0]) + (l[1] - c[1]))     # upper-left lobes first (highlight)
    lobes.append((c[0], c[1], r0 * 0.55))
    return lobes


def _molecules(snap, idx_set, near=None):
    """Lipid chains (head first) for molecules with at least one bead in idx_set.
    near (optional bool per bead): beads around the view; only bonds between near beads are
    considered (every molecule that touches idx_set lies entirely in near), which keeps this
    fast for boxes with millions of beads.  Same chains as without it."""
    t = snap.type
    b = snap.bonds
    if len(b) == 0:
        return []
    if near is not None:
        b = b[near[b[:, 0]] & near[b[:, 1]]]
    lip = (t == H) | (t == T)
    b = b[lip[b[:, 0]] & lip[b[:, 1]]]
    adj = {}
    for i, j in b.tolist():
        adj.setdefault(i, []).append(j); adj.setdefault(j, []).append(i)
    seen = set(); chains = []
    for i in idx_set:
        if i in seen or not lip[i]:
            continue
        # collect component
        comp = []; stack = [i]
        while stack:
            u = stack.pop()
            if u in seen:
                continue
            seen.add(u); comp.append(u); stack.extend(adj.get(u, []))
        ends = [u for u in comp if len(adj.get(u, [])) <= 1]
        start = next((u for u in ends if t[u] == H), ends[0] if ends else comp[0])
        chain = [start]; prev = -1; cur = start
        while True:
            nx = [v for v in adj.get(cur, []) if v != prev]
            if not nx:
                break
            prev, cur = cur, nx[0]
            if cur in chain:
                break
            chain.append(cur)
        chains.append(chain)
    return chains


def render(snap, center, size, width=2000, ss=3, label_grid=None, label_h=None, title=None,
           subtitle=None, seed=3, legend=True):
    """Return PIL image. center=(x,y) sim coords, size = field width (sim units).
    label_grid: periodic lumen label grid from cells.detect (for the washes)."""
    rng = np.random.default_rng(seed)
    L = snap.L
    Wp = width; Hp = width
    band = int(0.13 * width) if legend else 0
    ppu = Wp / size
    S = ss * ppu
    cx, cy = center
    x0 = cx - size / 2; y0 = cy - size / 2

    # ---------------------------------------------------------------- washes (final resolution)
    yy, xx = np.mgrid[0:Hp, 0:Wp]
    sx = x0 + (xx + 0.5) / ppu
    sy = y0 + size - (yy + 0.5) / ppu
    if label_grid is not None:
        ng = label_grid.shape[0]
        gi = np.floor(np.mod(sx, L) / label_h).astype(int) % ng
        gj = np.floor(np.mod(sy, L) / label_h).astype(int) % ng
        lum = (label_grid[gi, gj] >= 0).astype(np.float32)
        lum = ndimage.binary_dilation(lum > 0, iterations=max(1, int(0.9 * ppu))).astype(np.float32)
    else:
        lum = np.zeros((Hp, Wp), np.float32)
    # irregular, soft wash edge
    nz = _noise((Hp, Wp), 0.9 * ppu, rng)
    lum_s = ndimage.gaussian_filter(lum, 0.35 * ppu)
    lum_w = np.clip((lum_s - 0.5 + 0.10 * nz) * 6 + 0.5, 0, 1)
    edge = np.clip(1 - np.abs(lum_s - 0.5) * 4.0, 0, 1) ** 2        # pigment pooling at the edge
    lowf = _noise((Hp, Wp), 6 * ppu, rng)
    midf = _noise((Hp, Wp), 1.6 * ppu, rng)
    # granulation: pigment settling in the paper texture (stronger in the cool outside wash)
    gran = ndimage.gaussian_filter(rng.normal(0, 1, (Hp, Wp)).astype(np.float32), 1.1)
    gran = np.clip(gran * 0.9, -2, 2)
    # pigment density varies (paper shows through where thin, colour deepens where it pools),
    # never towards grey
    dens = np.clip(0.55 + 0.42 * lowf + 0.18 * midf - 0.10 * gran, 0, 1)[..., None]
    out_thin = PAL["outside"] * 0.45 + PAL["paper"] * 0.55
    out_full = PAL["outside"] * np.array([0.93, 0.985, 1.0])
    in_thin = PAL["lumen"] * 0.55 + PAL["paper"] * 0.45
    in_full = PAL["lumen"] * np.array([1.0, 0.965, 0.90])
    col_out = out_thin[None, None, :] * (1 - dens) + out_full[None, None, :] * dens
    col_in = in_thin[None, None, :] * (1 - dens) + in_full[None, None, :] * dens
    wash = col_out * (1 - lum_w[..., None]) + col_in * lum_w[..., None]
    wash *= (1 - 0.13 * edge[..., None])
    # watercolour vignette of the whole painting
    r = np.maximum(np.abs(xx - Wp / 2) / (Wp / 2), np.abs(yy - Hp / 2) / (Hp / 2))
    vig = np.clip((0.965 - r + 0.035 * _noise((Hp, Wp), 0.06 * Wp, rng) + 0.012 * nz) * 30, 0, 1)
    vig = ndimage.gaussian_filter(vig, 0.7)
    paper = PAL["paper"][None, None, :] * np.ones((Hp, Wp, 1))
    bg = paper * (1 - vig[..., None]) + wash * vig[..., None]
    # darker rim where the painted area ends (dried edge)
    rim = np.clip(1 - np.abs(vig - 0.5) * 2.2, 0, 1)
    bg *= (1 - 0.09 * rim[..., None])
    canvas = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").resize((Wp * ss, Hp * ss), Image.BICUBIC)
    draw = ImageDraw.Draw(canvas)

    # ---------------------------------------------------------------- beads in view (unwrapped)
    pos = np.stack([snap.x, snap.y], 1)
    d = pos - np.array([cx, cy]); d -= L * np.round(d / L)
    margin = 2.0
    inview = (np.abs(d[:, 0]) < size / 2 + margin) & (np.abs(d[:, 1]) < size / 2 + margin)
    # beads close enough to belong to a molecule that reaches into the view (a lipid is < 3 units long)
    near = (np.abs(d[:, 0]) < size / 2 + margin + 8.0) & (np.abs(d[:, 1]) < size / 2 + margin + 8.0)
    t = snap.type

    def P(i):
        return ((d[i, 0] + size / 2) * S, (size / 2 - d[i, 1]) * S)

    def circle(xy, r, fill, ink=None, w=0):
        x, y = xy
        if ink is not None:
            draw.ellipse([x - r - w, y - r - w, x + r + w, y + r + w], fill=ink)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)

    ink_w = SIZES["ink"] * S
    # fade objects near the painting's irregular border: skip beads outside the vignette
    vmask = vig

    def visible(i, rad=0.0):
        """Bead (with an object radius rad in sim units) lies fully inside the painted area."""
        px, py = P(i)
        rp = rad * S
        for ox, oy in ((0, 0), (rp, 0), (-rp, 0), (0, rp), (0, -rp)):
            ix, iy = int((px + ox) / ss), int((py + oy) / ss)
            if not (0 <= ix < Wp and 0 <= iy < Hp and vmask[iy, ix] > 0.85):
                return False
        return True

    # nutrients
    for i in np.nonzero(inview & (t == N))[0]:
        if visible(i, SIZES["nut_r"]):
            circle(P(i), SIZES["nut_r"] * S, _c(PAL["nut"], 0.03, rng), _c(PAL["nut_ink"]), ink_w * 0.6)

    # lipids
    idx = np.nonzero(inview & ((t == H) | (t == T)))[0]
    chains = _molecules(snap, set(idx.tolist()), near)
    chains = [c for c in chains if all(visible(i, SIZES["head_r"]) for i in c)]
    tw = SIZES["tail_w"] * S
    # pass 1: tail band, union outline (all outlines, then all fills)
    for c in chains:
        tails = [P(i) for i in c if t[i] == T]
        hd = [P(i) for i in c if t[i] == H]
        pts = (hd[-1:] + tails) if hd else tails
        if len(pts) >= 2:
            draw.line(pts, fill=_c(PAL["tail_ink"]), width=int(tw + 2 * ink_w), joint="curve")
        for p in pts[1:]:
            circle(p, (tw / 2 + ink_w), _c(PAL["tail_ink"]))
    for c in chains:
        tails = [P(i) for i in c if t[i] == T]
        hd = [P(i) for i in c if t[i] == H]
        pts = (hd[-1:] + tails) if hd else tails
        col = _c(PAL["tail"], 0.025, rng)
        if len(pts) >= 2:
            draw.line(pts, fill=col, width=int(tw), joint="curve")
        for p in pts[1:]:
            circle(p, tw / 2, col)
    # pass 2: one short stroke per tail
    lw = max(1, int(SIZES["tail_line"] * S))
    for c in chains:
        tails = [P(i) for i in c if t[i] == T]
        hd = [P(i) for i in c if t[i] == H]
        if hd and tails:
            a = np.array(hd[-1]); e = np.array(tails[-1])
            pts = [tuple(a + 0.45 * (np.array(tails[0]) - a))] + tails
        else:
            pts = tails
        if len(pts) >= 2:
            draw.line(pts, fill=_c(PAL["tail_line"], 0.03, rng), width=lw, joint="curve")
    # pass 3: heads, individually outlined
    hr = SIZES["head_r"] * S
    for c in chains:
        for i in c:
            if t[i] == H:
                circle(P(i), hr, _c(PAL["head"], 0.035, rng), _c(PAL["head_ink"]), ink_w)

    # Z (fallback division ring): bonded coral beads
    zi = np.nonzero(inview & (t == Z))[0]
    if len(zi):
        zs = set(zi.tolist())
        bz = snap.bonds[near[snap.bonds[:, 0]] & near[snap.bonds[:, 1]]] if len(snap.bonds) else snap.bonds
        for i, j in bz.tolist():
            if i in zs and j in zs:
                draw.line([P(i), P(j)], fill=_c(PAL["z_ink"]), width=int(0.5 * S))
        for i in zi:
            if visible(i):
                circle(P(i), SIZES["z_r"] * S, _c(PAL["z"], 0.03, rng), _c(PAL["z_ink"]), ink_w)

    # catalysts: lobed blobs with one union outline and a soft highlight
    for i in np.nonzero(inview & ((t == KA) | (t == KB)))[0]:
        if not visible(i, SIZES["cat_r"] + SIZES["ink"]):
            continue
        key = "ka" if t[i] == KA else "kb"
        r0 = SIZES["cat_r"] * S
        lobes = protein_lobes(P(i), r0, int(i))
        ink = _c(PAL[key + "_ink"]); fill = _c(PAL[key], 0.03, rng)
        for x, y, rr in lobes:
            draw.ellipse([x - rr - ink_w, y - rr - ink_w, x + rr + ink_w, y + rr + ink_w], fill=ink)
        for x, y, rr in lobes:
            draw.ellipse([x - rr, y - rr, x + rr, y + rr], fill=fill)
        # soft light from the upper left: a few slightly lighter lobes, no hard ring
        hl = _c(np.array(fill) * 0.80 + 255 * 0.20)
        for x, y, rr in lobes[:2]:
            draw.ellipse([x - 0.55 * rr - 0.25 * rr, y - 0.55 * rr - 0.30 * rr, x + 0.55 * rr - 0.25 * rr,
                          y + 0.55 * rr - 0.30 * rr], fill=hl)

    img = canvas.resize((Wp, Hp), Image.LANCZOS)
    # paper grain over everything (watercolour pigment granulation)
    arr = np.asarray(img).astype(np.float32)
    grain = rng.normal(0, 1, (Hp, Wp)).astype(np.float32)
    grain = ndimage.gaussian_filter(grain, 0.7) * 0.022 + _noise((Hp, Wp), 18, rng, 2) * 0.018
    fib = ndimage.gaussian_filter(rng.normal(0, 1, (Hp, Wp)).astype(np.float32), (0.6, 7)) * 0.03
    arr *= (1 + grain + fib)[..., None]
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")

    if legend:
        img = _legend(img, band, ppu, title, subtitle, size)
    return img


def _glyph(d, key, gx, gy, S):
    """Legend glyph drawn like the painting; returns the x where the label may start."""
    iw = SIZES["ink"] * S
    if key == "head":
        tw = SIZES["tail_w"] * S
        p0 = (gx, gy); p1 = (gx + 1.9 * S, gy)
        d.line([p0, p1], fill=_c(PAL["tail_ink"]), width=int(tw + 2 * iw))
        d.ellipse([p1[0] - tw / 2 - iw, gy - tw / 2 - iw, p1[0] + tw / 2 + iw, gy + tw / 2 + iw], fill=_c(PAL["tail_ink"]))
        d.line([p0, p1], fill=_c(PAL["tail"]), width=int(tw))
        d.ellipse([p1[0] - tw / 2, gy - tw / 2, p1[0] + tw / 2, gy + tw / 2], fill=_c(PAL["tail"]))
        d.line([(gx + 0.25 * S, gy), p1], fill=_c(PAL["tail_line"]), width=max(1, int(SIZES["tail_line"] * S)))
        r = SIZES["head_r"] * S
        d.ellipse([gx - r - iw, gy - r - iw, gx + r + iw, gy + r + iw], fill=_c(PAL["head_ink"]))
        d.ellipse([gx - r, gy - r, gx + r, gy + r], fill=_c(PAL["head"]))
        return gx + 2.7 * S
    if key in ("ka", "kb"):
        lobes = protein_lobes((gx + 0.8 * S, gy), SIZES["cat_r"] * S * 0.85, 11 if key == "ka" else 23)
        for (lx, ly, rr) in lobes:
            d.ellipse([lx - rr - iw, ly - rr - iw, lx + rr + iw, ly + rr + iw], fill=_c(PAL[key + "_ink"]))
        for (lx, ly, rr) in lobes:
            d.ellipse([lx - rr, ly - rr, lx + rr, ly + rr], fill=_c(PAL[key]))
        return gx + 2.3 * S
    r = SIZES["nut_r"] * S
    cxg = gx + 0.5 * S
    d.ellipse([cxg - r - iw, gy - r - iw, cxg + r + iw, gy + r + iw], fill=_c(PAL["nut_ink"]))
    d.ellipse([cxg - r, gy - r, cxg + r, gy + r], fill=_c(PAL["nut"]))
    return gx + 1.3 * S


def _legend(img, band, ppu, title, subtitle, size):
    Wp, Hp = img.size
    band = int(0.17 * Wp)
    out = Image.new("RGB", (Wp, Hp + band), _c(PAL["paper"]))
    out.paste(img, (0, 0))
    rng = np.random.default_rng(5)
    arr = np.asarray(out).astype(np.float32)
    g = ndimage.gaussian_filter(rng.normal(0, 1, arr.shape[:2]).astype(np.float32), 0.7) * 0.02
    arr[Hp:] *= (1 + g[Hp:])[..., None]
    out = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    ss = 3
    big = out.resize((Wp * ss, (Hp + band) * ss), Image.BICUBIC)
    d = ImageDraw.Draw(big)
    ink = _c(PAL["ink"])
    soft = _c(PAL["ink"] * 0.72 + 255 * 0.28)
    m = int(0.045 * Wp) * ss
    y = (Hp + int(0.022 * Wp)) * ss
    if title:
        d.text((m, y), title, font=style.font("SemiBold", int(0.024 * Wp) * ss), fill=ink, anchor="lt")
    if subtitle:
        d.text((m, y + int(0.034 * Wp) * ss), subtitle, font=style.font("Regular", int(0.0155 * Wp) * ss),
               fill=soft, anchor="lt")
    # scale bar (ink), right-aligned on the title row
    Lb = style.nice_length(0.12 * size * style.RC_NM) / style.RC_NM
    bx1 = Wp * ss - m; bx0 = bx1 - Lb * ppu * ss
    by = y + int(0.030 * Wp) * ss
    d.rectangle([bx0, by - int(0.0045 * Wp) * ss, bx1, by], fill=ink)
    d.text(((bx0 + bx1) / 2, by - int(0.012 * Wp) * ss), style.fmt_len_nm(Lb),
           font=style.font("Medium", int(0.0165 * Wp) * ss), fill=ink, anchor="ms")
    # thin rule, then one row of legend items
    yr = (Hp + int(0.083 * Wp)) * ss
    d.line([(m, yr), (Wp * ss - m, yr)], fill=_c(PAL["ink"] * 0.25 + PAL["paper"] * 0.75), width=ss)
    S = min(ppu, 0.03 * Wp) * ss * 0.95
    f = style.font("Regular", int(0.0158 * Wp) * ss)
    items = [("head", "lipide: kop + staarten"), ("ka", "katalysator a (langzaam)"),
             ("kb", "katalysator b (snel)"), ("nut", "voedingsstof")]
    gy = (Hp + int(0.122 * Wp)) * ss
    # measure total width, distribute evenly
    widths = []
    for key, txt in items:
        gw = {"head": 2.7, "ka": 2.3, "kb": 2.3, "nut": 1.3}[key] * S
        widths.append(gw + d.textlength(txt, font=f))
    gap = (Wp * ss - 2 * m - sum(widths)) / (len(items) - 1)
    x = m + 0.4 * S
    for (key, txt), w in zip(items, widths):
        tx = _glyph(d, key, x, gy, S)
        d.text((tx, gy), txt, font=f, fill=ink, anchor="lm")
        x += w + gap
    return big.resize((Wp, Hp + band), Image.LANCZOS)
