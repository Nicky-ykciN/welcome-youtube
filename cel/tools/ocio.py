"""Oercel I/O: snapshot, params, stats and event files (SPEC section 5).

Snapshot  snap_<step:010d>.bin, little-endian:
    char[4] magic "OCEL" | int32 version=1 | int32 N | int32 nbonds | int64 step
    float64 time | float64 L | float32 x[N] | float32 y[N] | uint8 type[N]
    int32 bonds[nbonds][2]
"""
import os
import re
import glob
from dataclasses import dataclass

import numpy as np

# bead types (SPEC section 2)
W, H, T, N, KA, KB, Z = 0, 1, 2, 3, 4, 5, 6
TYPE_NAMES = ["W", "H", "T", "N", "Ka", "Kb", "Z"]

MAGIC = b"OCEL"
VERSION = 1
_HDR = np.dtype([("magic", "S4"), ("version", "<i4"), ("N", "<i4"), ("nbonds", "<i4"),
                 ("step", "<i8"), ("time", "<f8"), ("L", "<f8")])
HEADER_BYTES = _HDR.itemsize  # 40

SNAP_RE = re.compile(r"snap_(\d+)\.bin$")


@dataclass
class Snapshot:
    step: int
    time: float
    L: float
    x: np.ndarray       # float64, wrapped into [0, L)
    y: np.ndarray
    type: np.ndarray    # uint8
    bonds: np.ndarray   # int64 (nbonds, 2)
    path: str = ""

    @property
    def n(self):
        return len(self.type)

    @property
    def pos(self):
        return np.stack([self.x, self.y], axis=1)


def wrap(a, L):
    """Wrap coordinates into [0, L) robustly (float rounding can give exactly L)."""
    a = np.mod(a, L)
    a[a >= L] -= L
    return a


def read_header(path):
    with open(path, "rb") as f:
        raw = f.read(HEADER_BYTES)
    if len(raw) < HEADER_BYTES:
        raise ValueError(f"{path}: truncated header")
    h = np.frombuffer(raw, dtype=_HDR, count=1)[0]
    if h["magic"] != MAGIC:
        raise ValueError(f"{path}: bad magic {h['magic']!r}")
    if int(h["version"]) != VERSION:
        raise ValueError(f"{path}: unsupported version {int(h['version'])}")
    return dict(N=int(h["N"]), nbonds=int(h["nbonds"]), step=int(h["step"]),
                time=float(h["time"]), L=float(h["L"]))


def read_snapshot(path):
    """Read one snapshot. Raises ValueError on a malformed / truncated file."""
    with open(path, "rb") as f:
        buf = f.read()
    if len(buf) < HEADER_BYTES:
        raise ValueError(f"{path}: truncated header")
    h = np.frombuffer(buf, dtype=_HDR, count=1)[0]
    if h["magic"] != MAGIC:
        raise ValueError(f"{path}: bad magic {h['magic']!r}")
    if int(h["version"]) != VERSION:
        raise ValueError(f"{path}: unsupported version {int(h['version'])}")
    n, nb = int(h["N"]), int(h["nbonds"])
    need = HEADER_BYTES + 4 * n + 4 * n + n + 8 * nb
    if len(buf) != need:
        raise ValueError(f"{path}: size {len(buf)} != expected {need} (N={n}, nbonds={nb})")
    o = HEADER_BYTES
    x = np.frombuffer(buf, "<f4", n, o).astype(np.float64); o += 4 * n
    y = np.frombuffer(buf, "<f4", n, o).astype(np.float64); o += 4 * n
    t = np.frombuffer(buf, "u1", n, o).copy(); o += n
    b = np.frombuffer(buf, "<i4", 2 * nb, o).reshape(nb, 2).astype(np.int64)
    L = float(h["L"])
    return Snapshot(step=int(h["step"]), time=float(h["time"]), L=L,
                    x=wrap(x, L), y=wrap(y, L), type=t, bonds=b, path=path)


def write_snapshot(path, step, time, L, x, y, types, bonds):
    """Write a snapshot exactly per SPEC section 5 (atomic rename)."""
    x = np.asarray(x, "<f4"); y = np.asarray(y, "<f4")
    types = np.asarray(types, "u1")
    bonds = np.asarray(bonds, "<i4").reshape(-1, 2)
    if len(bonds):
        lo = np.minimum(bonds[:, 0], bonds[:, 1]); hi = np.maximum(bonds[:, 0], bonds[:, 1])
        bonds = np.stack([lo, hi], 1).astype("<i4")
    n = len(types)
    assert len(x) == n and len(y) == n
    hdr = np.zeros(1, dtype=_HDR)
    hdr["magic"] = MAGIC; hdr["version"] = VERSION; hdr["N"] = n
    hdr["nbonds"] = len(bonds); hdr["step"] = step; hdr["time"] = time; hdr["L"] = L
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(hdr.tobytes()); f.write(x.tobytes()); f.write(y.tobytes())
        f.write(types.tobytes()); f.write(bonds.tobytes())
    os.replace(tmp, path)


def list_snapshots(rundir):
    """Sorted list of (step, path) for complete snapshot files in rundir."""
    out = []
    for p in glob.glob(os.path.join(rundir, "snap_*.bin")):
        m = SNAP_RE.search(os.path.basename(p))
        if m:
            out.append((int(m.group(1)), p))
    out.sort()
    return out


def snapshot_is_complete(path):
    try:
        h = read_header(path)
    except (ValueError, OSError):
        return False
    need = HEADER_BYTES + 9 * h["N"] + 8 * h["nbonds"]
    return os.path.getsize(path) == need


def read_params(path_or_dir):
    """params.ini -> dict of str -> value (int/float/str). Sections ([x]) are flattened."""
    path = path_or_dir
    if os.path.isdir(path):
        path = os.path.join(path, "params.ini")
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].split(";", 1)[0].strip()
            if not line or line.startswith("[") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip(); v = v.strip()
            out[k] = _convert(v)
    return out


def _convert(v):
    for conv in (int, float):
        try:
            return conv(v)
        except ValueError:
            pass
    return v


def read_stats(rundir):
    """stats.csv -> pandas DataFrame (empty DataFrame if missing)."""
    import pandas as pd
    p = os.path.join(rundir, "stats.csv")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return pd.DataFrame()
    df = pd.read_csv(p, comment="#", skipinitialspace=True)
    df.columns = [c.strip() for c in df.columns]
    return df


_VARIANT_MAP = {"a": "a", "A": "a", "Ka": "a", "ka": "a", "KA": "a",
                "b": "b", "B": "b", "Kb": "b", "kb": "b", "KB": "b"}


def normalise_variant(v):
    s = str(v).strip()
    if s in _VARIANT_MAP:
        return _VARIANT_MAP[s]
    # numeric conventions: bead type id (4/5) or variant index (0/1)
    if s in ("4", "0"):
        return "a"
    if s in ("5", "1"):
        return "b"
    return ""


def read_events(rundir, kinds=None):
    """events.csv -> pandas DataFrame with columns step, kind, i, x, y, variant ('a'/'b'/'').

    kinds: optional iterable of kinds to keep (saves memory on huge logs)."""
    import pandas as pd
    p = os.path.join(rundir, "events.csv")
    cols = ["step", "kind", "i", "x", "y", "variant"]
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return pd.DataFrame(columns=cols)
    df = pd.read_csv(p, comment="#", skipinitialspace=True, dtype={"variant": str, "kind": str},
                     on_bad_lines="skip")
    df.columns = [c.strip() for c in df.columns]
    if "kind" not in df.columns:   # header-less file
        df = pd.read_csv(p, header=None, names=cols, dtype={"variant": str, "kind": str},
                         on_bad_lines="skip")
    df["kind"] = df["kind"].astype(str).str.strip()
    if kinds is not None:
        df = df[df["kind"].isin(list(kinds))]
    if "variant" not in df.columns:
        df["variant"] = ""
    vmap = {v: normalise_variant(v) for v in df["variant"].fillna("").unique()}
    df["variant"] = df["variant"].fillna("").map(vmap)
    for c in ("step", "i"):
        df[c] = pd.to_numeric(df[c], errors="coerce").fillna(-1).astype(np.int64)
    for c in ("x", "y"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.reset_index(drop=True)


def fmt_int_nl(v):
    """Dutch thousands separator: 1234567 -> '1.234.567'."""
    s = f"{int(round(v)):,}"
    return s.replace(",", ".")


def fmt_float_nl(v, nd=1):
    s = f"{v:,.{nd}f}"
    return s.replace(",", "X").replace(".", ",").replace("X", ".")
