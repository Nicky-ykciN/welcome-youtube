"""Shared look: fonts, Dutch formatting, overlays (scale bar, time stamp, legends)."""
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import ocio

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.path.join(HERE, "fonts")
_FALLBACK = {
    "Regular": "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "Medium": "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "SemiBold": "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "Light": "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "Italic": "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf",
}
_cache = {}

# physical scale used for scale bars: 1 DPD length unit r_c ~ 1 nm (a bilayer of this model is
# ~4 r_c thick, a real lipid bilayer ~4-5 nm). Override with --rc-nm.
RC_NM = 1.0


def font(weight="Regular", size=20):
    key = (weight, int(size))
    if key not in _cache:
        p = os.path.join(FONT_DIR, f"Inter-{weight}.otf")
        try:
            _cache[key] = ImageFont.truetype(p, int(size))
        except OSError:
            try:
                _cache[key] = ImageFont.truetype(_FALLBACK.get(weight, _FALLBACK["Regular"]), int(size))
            except OSError:
                _cache[key] = ImageFont.load_default()
    return _cache[key]


def nice_length(target):
    """1, 2, 5 x 10^n closest below target."""
    if target <= 0:
        return 1.0
    e = math.floor(math.log10(target))
    best = 10 ** e
    for m in (1, 2, 5, 10):
        if m * 10 ** e <= target:
            best = m * 10 ** e
    return best


def fmt_len_nm(units):
    nm = units * RC_NM
    if nm >= 1000:
        return f"{ocio.fmt_float_nl(nm / 1000, 0 if nm % 1000 == 0 else 1)} µm"
    return f"{nm:g} nm".replace(".", ",")


def fmt_time(t):
    """Simulation time in DPD units tau, Dutch number format."""
    if t >= 100:
        return f"t = {ocio.fmt_int_nl(round(t))} τ"
    return f"t = {ocio.fmt_float_nl(t, 1)} τ"


def text_with_shadow(img, xy, text, fnt, fill=(255, 255, 255, 235), shadow=(0, 0, 0, 160), radius=None,
                     anchor="la"):
    """Draw text with a soft blurred shadow onto RGBA/RGB image (in place). Returns bbox."""
    radius = radius if radius is not None else max(1, fnt.size // 12)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.text((xy[0], xy[1] + max(1, fnt.size // 18)), text, font=fnt, fill=shadow, anchor=anchor)
    layer = layer.filter(ImageFilter.GaussianBlur(radius))
    d = ImageDraw.Draw(layer)
    d.text(xy, text, font=fnt, fill=fill, anchor=anchor)
    base = img.convert("RGBA")
    base.alpha_composite(layer)
    img.paste(base.convert(img.mode))
    return ImageDraw.Draw(img).textbbox(xy, text, font=fnt, anchor=anchor)


def scale_bar(img, ppu, corner="br", color=(255, 255, 255, 235), margin=None, frac=0.16, label=True,
              shadow=True, font_scale=1.0):
    """Scale bar of a nice length (in nm, see RC_NM) in a corner. ppu = pixels per sim unit."""
    W, H = img.size
    margin = margin if margin is not None else int(0.035 * W)
    L_units = nice_length(frac * W / ppu * RC_NM) / RC_NM
    bar = L_units * ppu
    th = max(3, int(round(0.0055 * W)))
    fs = max(12, int(0.021 * W * font_scale))
    fnt = font("Medium", fs)
    txt = fmt_len_nm(L_units)
    if corner == "br":
        x1 = W - margin; x0 = x1 - bar; y1 = H - margin; y0 = y1 - th
    else:
        x0 = margin; x1 = x0 + bar; y1 = H - margin; y0 = y1 - th
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    if shadow:
        d.rectangle([x0, y0 + 1, x1, y1 + 1], fill=(0, 0, 0, 140))
        layer = layer.filter(ImageFilter.GaussianBlur(max(1, th // 2)))
        d = ImageDraw.Draw(layer)
    d.rectangle([x0, y0, x1, y1], fill=color)
    base = img.convert("RGBA"); base.alpha_composite(layer); img.paste(base.convert(img.mode))
    if label:
        tx = (x0 + x1) / 2
        if shadow:
            text_with_shadow(img, (tx, y0 - th * 1.6), txt, fnt, fill=color, anchor="ms")
        else:
            ImageDraw.Draw(img).text((tx, y0 - th * 1.6), txt, font=fnt, fill=color, anchor="ms")
    return L_units


def downsample(img, factor):
    if factor == 1:
        return img
    W, H = img.size
    return img.resize((W // factor, H // factor), Image.LANCZOS)
