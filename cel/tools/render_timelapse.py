"""Division time-lapse strip (SPEC 8.3): 4-6 fluorescence frames following one cell through
division, Dutch phase labels chosen from the measured shape (aspect ratio, solidity)."""
import numpy as np
from PIL import Image, ImageDraw

import ocio
import render_micro as rm
import style


def periodic_mid(p, q, L):
    d = np.array(q) - np.array(p)
    d -= L * np.round(d / L)
    m = np.array(p) + d / 2
    return m % L


def pick_frames(parent, kids, n_panels=5):
    """Choose (step, label, kind) panels from the parent track series and daughter series."""
    ps = parent["series"]
    steps = ps["step"]
    asp = np.array(ps["aspect"], float)
    sol = np.array(ps["solidity"], float)
    npar = len(steps)
    kd_steps = kids[0]["series"]["step"]
    panels = []
    # last parent frame = strongest constriction usually; use min solidity in last 3 frames
    tail = list(range(max(0, npar - 3), npar))
    i_con = tail[int(np.argmin(sol[tail]))]
    # elongation: first frame with aspect >= 1.35 before i_con, else midway
    cand = [i for i in range(i_con) if asp[i] >= 1.35]
    i_el = cand[0] if cand else max(0, i_con - 2)
    # growth: well before elongation
    i_gr = max(0, min(i_el - 3, npar - 1)) if i_el >= 1 else 0
    chosen = []
    for i, lab in ((i_gr, "groei"), (i_el, "strekking"), (i_con, "insnoering")):
        if i not in [c[0] for c in chosen]:
            chosen.append((i, lab))
    chosen.sort()
    for i, lab in chosen:
        if lab == "strekking" and asp[i] < 1.3:
            lab = "groei"
        if lab == "insnoering" and sol[i] > 0.92:
            lab = "strekking" if asp[i] >= 1.3 else "groei"
        panels.append(dict(step=steps[i], label=lab, phase="ouder"))
    panels.append(dict(step=kd_steps[0], label="deling", phase="dochters"))
    nd = min(len(k["series"]["step"]) for k in kids)
    extra = n_panels - len(panels)
    if extra > 0 and nd > 1:
        idx = sorted({min(nd - 1, j) for j in np.linspace(min(3, nd - 1), nd - 1, extra).round().astype(int)})
        for j in idx:
            if j == 0:
                continue
            panels.append(dict(step=kd_steps[j], label="twee dochtercellen", phase="dochters"))
    return panels[:6]


def _arrowheads(img, p, info, L):
    """Small white arrowheads pointing at the tracked cell(s), like in microscopy figures."""
    from PIL import ImageFilter
    x0, y0, w, h = info["view"]
    ppu = info["ppu"]
    W, H = img.size
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    da = ImageDraw.Draw(layer); ds = ImageDraw.Draw(shadow)
    for c in p.get("cells", []):
        dx = (c["x"] - x0) % L; dy = (c["y"] - y0) % L
        px, py = dx * ppu, (h - dy) * ppu
        rr = (0.5 * c["extent"] * 0.75 + 5.2) * ppu
        u = np.array([0.62, -0.78])                     # from upper right
        tip = np.array([px, py]) + u * rr
        back = tip + u * 0.075 * W
        nrm = np.array([-u[1], u[0]])
        tri = [tuple(tip), tuple(back + nrm * 0.026 * W), tuple(back - nrm * 0.026 * W)]
        if not (0 <= tip[0] < W and 0 <= tip[1] < H):
            continue
        ds.polygon([(a + 2, b + 3) for a, b in tri], fill=(0, 0, 0, 150))
        da.polygon(tri, fill=(255, 255, 255, 235))
    shadow = shadow.filter(ImageFilter.GaussianBlur(3))
    base = img.convert("RGBA"); base.alpha_composite(shadow); base.alpha_composite(layer)
    img.paste(base.convert("RGB"))


def _cell_at(frames_by_step, step, track):
    f = frames_by_step.get(step)
    if f is None:
        return None
    return next((c for c in f["cells"] if c.get("track") == track), None)


def render(rundir, cells_json, lineage, event, panel_px=720, gap=16, n_panels=5, prm=None):
    """Render the strip for a division event (dict from lineage['events'])."""
    tracks = {t["id"]: t for t in lineage["tracks"]}
    parent = tracks[event["parents"][0]]
    kids = [tracks[c] for c in event["children"]][:2]
    fbs = {f["step"]: f for f in cells_json["frames"]}
    snaps = dict(ocio.list_snapshots(rundir))
    L = cells_json["frames"][0]["L"]
    panels = pick_frames(parent, kids, n_panels)
    # centres and field size
    for p in panels:
        if p["phase"] == "ouder":
            c = _cell_at(fbs, p["step"], parent["id"])
            p["center"] = (c["x"], c["y"]); p["cells"] = [c]
            p["need"] = c["extent"] + 10
        else:
            cs = [_cell_at(fbs, p["step"], k["id"]) for k in kids]
            cs = [c for c in cs if c is not None]
            p["cells"] = cs
            if len(cs) == 2:
                mid = periodic_mid((cs[0]["x"], cs[0]["y"]), (cs[1]["x"], cs[1]["y"]), L)
                d = np.array([cs[1]["x"] - cs[0]["x"], cs[1]["y"] - cs[0]["y"]]); d -= L * np.round(d / L)
                p["center"] = tuple(mid); p["need"] = float(np.hypot(*d)) + 2 * max(c["r_eq"] for c in cs) + 10
            else:
                c = cs[0]; p["center"] = (c["x"], c["y"]); p["need"] = c["extent"] + 10
    size = min(L, 1.15 * max(p["need"] for p in panels))
    # one normalisation for the whole strip (same 'exposure')
    imgs = []
    norm = None
    t0 = None
    for j, p in enumerate(panels):
        snap = ocio.read_snapshot(snaps[p["step"]])
        view = rm.cell_view(L, p["center"][0], p["center"][1], size)
        if norm is None:
            ch = rm.channel_images(snap, view, panel_px, panel_px, dict(rm.DEFAULT, **(prm or {})), 2)
            norm = rm.auto_norm(ch)
        img, info = rm.render(snap, view, panel_px, panel_px, ss=2, prm=prm, norm=norm, overlay=False, seed=11 + j)
        if t0 is None:
            t0 = snap.time
        p["dt"] = snap.time - t0
        p["time"] = snap.time
        imgs.append((img, info))
    n = len(panels)
    margin = int(0.05 * panel_px)
    head = int(0.205 * panel_px)
    foot = int(0.19 * panel_px)
    Wt = n * panel_px + (n - 1) * gap + 2 * margin
    Ht = head + panel_px + foot
    bg = (12, 12, 14)
    out = Image.new("RGB", (Wt, Ht), bg)
    d = ImageDraw.Draw(out)
    f_title = style.font("SemiBold", int(0.062 * panel_px))
    f_sub = style.font("Regular", int(0.036 * panel_px))
    f_lab = style.font("SemiBold", int(0.042 * panel_px))
    f_t = style.font("Regular", int(0.029 * panel_px))
    d.text((margin, int(0.045 * panel_px)), "Deling van een oercel", font=f_title, fill=(238, 238, 240), anchor="lt")
    sub = (f"spoor {parent['id']} → {' + '.join(str(k['id']) for k in kids)}   ·   stap "
           f"{ocio.fmt_int_nl(panels[0]['step'])} – {ocio.fmt_int_nl(panels[-1]['step'])}   ·   "
           f"gesimuleerde fluorescentie, gelijke vergroting en belichting")
    d.text((margin, int(0.045 * panel_px) + int(0.085 * panel_px)), sub, font=f_sub, fill=(158, 158, 166), anchor="lt")
    for j, ((img, info), p) in enumerate(zip(imgs, panels)):
        x = margin + j * (panel_px + gap)
        if j == 0:
            style.scale_bar(img, info["ppu"], corner="br", frac=0.25, font_scale=1.6)
        _arrowheads(img, p, info, L)
        tag = "t = 0 τ" if j == 0 else f"+{ocio.fmt_int_nl(round(p['dt']))} τ"
        style.text_with_shadow(img, (int(0.05 * panel_px), int(0.05 * panel_px)), tag,
                               style.font("Medium", int(0.040 * panel_px)), anchor="lt")
        out.paste(img, (x, head))
        cx = x + panel_px / 2
        ly = head + panel_px + int(0.085 * panel_px)
        d.text((cx, ly), p["label"], font=f_lab, fill=(236, 236, 238), anchor="mm")
        d.text((cx, ly + int(0.052 * panel_px)), f"stap {ocio.fmt_int_nl(p['step'])}", font=f_t,
               fill=(140, 140, 148), anchor="mm")
    # time axis: thin line with a marker under every panel
    ty = head + panel_px + int(0.030 * panel_px)
    xs = [margin + j * (panel_px + gap) + panel_px / 2 for j in range(n)]
    d.line([(xs[0], ty), (xs[-1], ty)], fill=(80, 80, 88), width=max(2, panel_px // 300))
    r = max(4, panel_px // 110)
    for j, xx in enumerate(xs):
        col = (236, 236, 238) if panels[j]["label"] == "deling" else (150, 150, 158)
        d.ellipse([xx - r, ty - r, xx + r, ty + r], fill=col)
    return out, panels
