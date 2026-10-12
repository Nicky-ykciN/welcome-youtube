"""Tracking cells over snapshots by lumen overlap; divisions, fusions, deaths, lineage.

Nodes are (k, cid): cell cid in frame k.  Links between frames k and k+g (g = 1..3) come from
pixel overlap of the periodic lumen label grids (plus a centroid-distance fallback for
cells that moved further than their own size).

Rules (all thresholds in TRACK_DEFAULTS):
  * 1 -> 1           continuation
  * 1 -> n (n >= 2)  split. A child is 'valid' when its descendants persist for
                     `confirm_frames` snapshots, stay disjoint from the siblings' descendants
                     (no re-fusion), and miss at most one snapshot. >= 2 valid children =
                     division ('deling'); otherwise the parent continues into the (largest)
                     valid child and the rest are 'afsplitsing' fragments.
  * n -> 1           merge. >= 2 non-fragment parents = fusion ('fusie'); otherwise the
                     non-fragment parent continues and fragments are absorbed.
  * n -> m           greedy max-overlap matching ('herschikking').
  * no successor     the track ends; if a cell re-appears within max_gap snapshots at the
                     same place (overlap) the track is bridged, otherwise 'verdwenen'.
  * no predecessor   new track ('nieuw gevormd') - a vesicle that closed by self-assembly.
"""
import numpy as np

TRACK_DEFAULTS = dict(
    overlap_frac=0.25,     # overlap / min(area_a, area_b) needed for a link
    confirm_frames=3,      # persistence needed for a division to count
    max_gap=2,             # snapshots a cell may be missed (bridged by gap links)
    dist_factor=1.0,       # centroid fallback: distance < dist_factor * (r_a + r_b)
)


def overlaps(lab_a, lab_b):
    """Pixel overlap counts between two label grids (int, -1 = background)."""
    m = (lab_a >= 0) & (lab_b >= 0)
    if not m.any():
        return []
    ka = lab_a[m].astype(np.int64); kb = lab_b[m].astype(np.int64)
    mul = max(65536, int(kb.max()) + 1)          # any number of cells (labels may exceed int16)
    keys = ka * mul + kb
    u, c = np.unique(keys, return_counts=True)
    return [(int(x // mul), int(x % mul), int(n)) for x, n in zip(u, c)]


def area_px(lab, n):
    v = lab[lab >= 0].ravel()
    return np.bincount(v, minlength=n) if n else np.zeros(0, np.int64)


def make_links(ov, areas_a, areas_b, cfg):
    """Filter raw overlaps into links [(a, b, overlap_px, frac)]."""
    out = []
    for a, b, n in ov:
        if a >= len(areas_a) or b >= len(areas_b):
            continue
        frac = n / max(1, min(areas_a[a], areas_b[b]))
        if frac >= cfg["overlap_frac"]:
            out.append((a, b, n, round(float(frac), 3)))
    return out


def distance_links(cells_a, cells_b, links, L, cfg):
    """Centroid fallback for cells without any overlap link."""
    has_out = {a for a, b, *_ in links}
    has_in = {b for a, b, *_ in links}
    cand = []
    for a, ca in enumerate(cells_a):
        if a in has_out:
            continue
        for b, cb in enumerate(cells_b):
            if b in has_in:
                continue
            d = np.array([cb["x"] - ca["x"], cb["y"] - ca["y"]])
            d -= L * np.round(d / L)
            dist = float(np.hypot(*d))
            ratio = cb["area"] / max(ca["area"], 1e-9)
            if dist < cfg["dist_factor"] * (ca["r_eq"] + cb["r_eq"]) and 0.5 <= ratio <= 2.0:
                cand.append((dist, a, b))
    cand.sort()
    used_a, used_b, out = set(), set(), []
    for dist, a, b in cand:
        if a in used_a or b in used_b:
            continue
        used_a.add(a); used_b.add(b)
        out.append((a, b, 0, 0.0))
    return out


class Tracker:
    def __init__(self, frames, links, cfg=None):
        """frames: list of dict(step, time, cells=[...]); links: dict {(k, g): [(a,b,ov,frac)]}"""
        self.cfg = dict(TRACK_DEFAULTS)
        if cfg:
            self.cfg.update(cfg)
        self.frames = frames
        self.K = len(frames)
        self.succ = {}   # (g, k, a) -> list of (b, ov, frac)
        self.pred = {}
        for (k, g), lst in links.items():
            for a, b, ov, frac in lst:
                self.succ.setdefault((g, k, a), []).append((b, ov, frac))
                self.pred.setdefault((g, k + g, b), []).append((a, ov, frac))
        self.tracks = []
        self.track_of = {}
        self.events = []

    # ------------------------------------------------------------------ helpers
    def _area(self, node):
        k, c = node
        return self.frames[k]["cells"][c]["area"]

    def _reach(self, node, depth):
        """Descendant node sets R_d (d = 0..depth) from node, using gap links too."""
        k0 = node[0]
        R = [{node[1]}]
        for d in range(1, depth + 1):
            k = k0 + d
            if k >= self.K:
                break
            s = set()
            for g in range(1, self.cfg["max_gap"] + 2):
                if d - g < 0:
                    break
                for a in R[d - g]:
                    for b, ov, fr in self.succ.get((g, k - g, a), []):
                        if g == 1 or not self.pred.get((1, k, b)):
                            s.add(b)
            R.append(s)
        return R

    def _valid_children(self, k, children):
        """children are cell ids in frame k + 1."""
        m = self.cfg["confirm_frames"]
        reach = {c: self._reach((k + 1, c), m) for c in children}
        valid, censored = [], False
        for c in children:
            R = reach[c]
            if len(R) < m + 1:            # run ends before confirmation
                censored = True
                last = R[-1]
                ok = bool(last) and all(not (last & reach[o][len(R) - 1]) for o in children if o != c and len(reach[o]) >= len(R))
            else:
                last = R[m]
                empties = sum(1 for d in range(1, m + 1) if not R[d])
                disjoint = all(not (last & reach[o][m]) for o in children if o != c and len(reach[o]) > m)
                ok = bool(last) and disjoint and empties <= 1
            if ok:
                valid.append(c)
        return valid, censored

    def _new_track(self, node, reason, parents=(), fragment=False):
        tid = len(self.tracks)
        self.tracks.append(dict(id=tid, nodes=[node], start_reason=reason, end_reason=None,
                                parents=list(parents), children=[], fragment=fragment))
        self.track_of[node] = tid
        for p in parents:
            self.tracks[p]["children"].append(tid)
        return tid

    def _extend(self, tid, node):
        self.tracks[tid]["nodes"].append(node)
        self.track_of[node] = tid

    def _end(self, tid, reason):
        if self.tracks[tid]["end_reason"] is None:
            self.tracks[tid]["end_reason"] = reason

    # ------------------------------------------------------------------ main
    def run(self):
        K = self.K
        if K == 0:
            return self
        for c in range(len(self.frames[0]["cells"])):
            self._new_track((0, c), "aanwezig bij start")
        for k in range(K - 1):
            nA = len(self.frames[k]["cells"]); nB = len(self.frames[k + 1]["cells"])
            # union-find over A (0..nA-1) and B (nA..nA+nB-1)
            par = list(range(nA + nB))

            def find(x):
                while par[x] != x:
                    par[x] = par[par[x]]
                    x = par[x]
                return x
            ov = {}
            for a in range(nA):
                for b, o, fr in self.succ.get((1, k, a), []):
                    par[find(a)] = find(nA + b)
                    ov[(a, b)] = o if o > 0 else 1
            comps = {}
            for x in range(nA + nB):
                comps.setdefault(find(x), []).append(x)
            continued = set()
            step = self.frames[k + 1]["step"]
            for members in comps.values():
                P = [x for x in members if x < nA]
                C = [x - nA for x in members if x >= nA]
                if not P or not C:
                    continue
                Ptid = [self.track_of[(k, p)] for p in P]
                if len(P) == 1 and len(C) == 1:
                    self._extend(Ptid[0], (k + 1, C[0])); continued.add(Ptid[0])
                elif len(P) == 1:
                    self._split(k, P[0], Ptid[0], C, step); continued.add(Ptid[0])
                elif len(C) == 1:
                    self._merge(k, P, Ptid, C[0], step); continued.update(Ptid)
                else:
                    self._complex(k, P, Ptid, C, ov, step); continued.update(Ptid)
            # unlinked children: gap bridging or new tracks
            for b in range(nB):
                if (k + 1, b) in self.track_of:
                    continue
                best = None
                for g in range(2, self.cfg["max_gap"] + 2):
                    for a, o, fr in self.pred.get((g, k + 1, b), []):
                        src = (k + 1 - g, a)
                        tid = self.track_of.get(src)
                        if tid is None:
                            continue
                        t = self.tracks[tid]
                        if t["nodes"][-1] != src or t["end_reason"] not in (None, "verdwenen"):
                            continue
                        if self.succ.get((1, src[0], a)):
                            continue
                        if best is None or o > best[0]:
                            best = (o, tid)
                if best is not None:
                    tid = best[1]
                    self.tracks[tid]["end_reason"] = None
                    self.tracks[tid].setdefault("gaps", []).append(int(self.frames[k + 1]["step"]))
                    self._extend(tid, (k + 1, b))
                else:
                    self._new_track((k + 1, b), "nieuw gevormd")
            # tracks whose last node is at k and were not continued: tentatively ended
            for a in range(nA):
                tid = self.track_of[(k, a)]
                t = self.tracks[tid]
                if t["nodes"][-1] == (k, a) and tid not in continued and t["end_reason"] is None:
                    t["end_reason"] = "verdwenen"
        for t in self.tracks:
            if t["end_reason"] is None:
                t["end_reason"] = "einde run" if t["nodes"][-1][0] == K - 1 else "verdwenen"
        self._generations()
        return self

    def _split(self, k, p, ptid, C, step):
        valid, censored = self._valid_children(k, C)
        C_sorted = sorted(C, key=lambda c: -self._area((k + 1, c)))
        if len(valid) >= 2:
            self._end(ptid, "deling")
            kids = []
            for c in C_sorted:
                frag = c not in valid
                kids.append(self._new_track((k + 1, c), "afsplitsing" if frag else "dochter", [ptid], fragment=frag))
            self.events.append(dict(kind="deling", k=k + 1, step=int(step), parents=[ptid],
                                    children=[self.track_of[(k + 1, c)] for c in C_sorted if c in valid],
                                    fragments=[self.track_of[(k + 1, c)] for c in C_sorted if c not in valid],
                                    confirmed=not censored))
        else:
            main = max(valid, key=lambda c: self._area((k + 1, c))) if valid else C_sorted[0]
            self._extend(ptid, (k + 1, main))
            frs = []
            for c in C_sorted:
                if c != main:
                    frs.append(self._new_track((k + 1, c), "afsplitsing", [ptid], fragment=True))
            self.events.append(dict(kind="afsplitsing", k=k + 1, step=int(step), parents=[ptid],
                                    children=frs, continues=ptid))

    def _merge(self, k, P, Ptid, c, step):
        nonfrag = [t for t in Ptid if not self.tracks[t]["fragment"]]
        if len(nonfrag) >= 2:
            for t in Ptid:
                self._end(t, "fusie")
            nt = self._new_track((k + 1, c), "fusie", Ptid)
            self.events.append(dict(kind="fusie", k=k + 1, step=int(step), parents=Ptid, children=[nt]))
        else:
            if nonfrag:
                main = nonfrag[0]
            else:
                main = Ptid[int(np.argmax([self._area((k, p)) for p in P]))]
            self._extend(main, (k + 1, c))
            others = [t for t in Ptid if t != main]
            for t in others:
                self._end(t, "opgegaan")
            self.events.append(dict(kind="opname", k=k + 1, step=int(step), parents=Ptid,
                                    children=[main], continues=main))

    def _complex(self, k, P, Ptid, C, ov, step):
        pairs = sorted(((o, a, b) for (a, b), o in ov.items() if a in P and b in C), reverse=True)
        used_a, used_b = set(), set()
        for o, a, b in pairs:
            if a in used_a or b in used_b:
                continue
            used_a.add(a); used_b.add(b)
            self._extend(self.track_of[(k, a)], (k + 1, b))
        kids = []
        for b in C:
            if b in used_b:
                continue
            linked = sorted({self.track_of[(k, a)] for (a, bb) in ov if bb == b and a in P})
            kids.append(self._new_track((k + 1, b), "herschikking", linked))
        for a in P:
            if a not in used_a:
                self._end(self.track_of[(k, a)], "herschikking")
        self.events.append(dict(kind="herschikking", k=k + 1, step=int(step), parents=Ptid,
                                children=kids))

    def _generations(self):
        for t in self.tracks:
            t["generation"] = None
        changed = True
        while changed:
            changed = False
            for t in self.tracks:
                if t["generation"] is not None:
                    continue
                if not t["parents"]:
                    t["generation"] = 0; changed = True
                elif all(self.tracks[p]["generation"] is not None for p in t["parents"]):
                    g = max(self.tracks[p]["generation"] for p in t["parents"])
                    t["generation"] = g + (1 if t["start_reason"] in ("dochter",) else 0)
                    changed = True
