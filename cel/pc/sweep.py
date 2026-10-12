#!/usr/bin/env python3
"""Oercel: run a list of parameter variants (x seeds) in parallel on many cores, resumable.

  pc/sweep.py JOBBESTAND [--jobs N] [--threads K] [--achtergrond]   start of hervat (zelfde commando)
  pc/sweep.py --hervat NAAM [--achtergrond]                          hervat met de opgeslagen definitie
  pc/sweep.py --stop NAAM                                            netjes stoppen (checkpoints)
  pc/sweep.py --samenvatting NAAM                                    alleen SAMENVATTING.md opnieuw maken
  pc/sweep.py JOBBESTAND --proef                                     alleen de joblijst en commando's tonen

Job file (text; JSON or YAML with the same keys also work, see pc/voorbeelden/):

  naam  = membraan_scan                         # sweep name -> runs/membraan_scan/ (default: file name)
  basis = notes/membranen/teamA_membranes.ini   # base ini (relative to cel/ or to the job file)
  seeds = 1-4                                   # or: 1 2 3 4  -> every variant once per seed
  steps = 200000                                # any other key = value here: override for ALL jobs
  zet   = snap_every=2000 chem=0                # same, several on one line
  raster a_N_T = 55 60 65                       # grid: every combination becomes a variant
  raster k_angle = 10 15
  [stijf]                                       # an explicit variant (combined with the grid)
  k_angle = 30

Each job (variant x seed) runs in runs/<sweep>/<job>/ with the normal engine output, in chunks
with checkpoints (engine option walltime): after a crash, kill or reboot, the same command
continues every job from its last checkpoint (bit-for-bit identical to an uninterrupted run).
Finished jobs are analysed with tools/analyze.py; runs/<sweep>/SAMENVATTING.md (+ .csv) ranks
jobs and variants by life-checklist rows, divisions, closed cells and cells with catalysts.
Defaults are sized for the 64-core Threadripper: K = 2 threads per job, N = (logical CPUs - 2) / K.
"""
import argparse
import itertools
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pclib as P  # noqa: E402

STATE = "pc_sweep.json"
STOP_REQ = "pc_stop_verzoek"      # written by --stop: a deliberate stop (status.py --hervat leaves it alone)
VERSION = 1
MAX_FAILURES = 4
GPU_PARALLEL_DEFAULT = 4          # jobs at a time when every job runs on the (single) GPU
CKPT_ERR_RE = re.compile(r"checkpoint|ckpt", re.I)

SPECIAL = {"naam": "name", "name": "name", "basis": "base", "base": "base", "seeds": "seeds", "zet": "set",
           "set": "set", "engine": "engine", "threads": "threads", "jobs": "jobs", "parallel": "jobs"}


# ----------------------------------------------------------------------------- job file
def parse_seeds(v):
    if isinstance(v, (list, tuple)):
        return [int(x) for x in v]
    out = []
    for tok in re.split(r"[,\s]+", str(v).strip()):
        if not tok:
            continue
        m = re.match(r"^(\d+)-(\d+)$", tok)
        if m:
            out += list(range(int(m.group(1)), int(m.group(2)) + 1))
        else:
            out.append(int(tok))
    return out


def parse_text(path):
    d = dict(name=None, base=None, seeds=None, set={}, grid={}, variants={}, engine=None, threads=None, jobs=None)
    cur = None  # current variant dict
    order = []
    with open(path, encoding="utf-8") as f:
        for ln, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            m = re.match(r"^\[(.+)\]$", line)
            if m:
                vn = m.group(1).strip()
                if vn in d["variants"]:
                    raise SystemExit(f"{path}:{ln}: variant [{vn}] staat er twee keer in")
                cur = d["variants"][vn] = dict(set={}, grid={})
                order.append(vn)
                continue
            m = re.match(r"^(raster|grid)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", line)
            if m:
                vals = [x for x in re.split(r"[,\s]+", m.group(3).strip()) if x]
                (cur["grid"] if cur is not None else d["grid"])[m.group(2)] = vals
                continue
            if "=" not in line:
                raise SystemExit(f"{path}:{ln}: verwacht 'sleutel = waarde', '[variant]' of 'raster sleutel = w1 w2 ...'")
            k, v = [x.strip() for x in line.split("=", 1)]
            if cur is None and k in SPECIAL:
                kk = SPECIAL[k]
                if kk == "set":
                    d["set"].update(P.parse_kv_list(v.split()))
                elif kk == "seeds":
                    d["seeds"] = parse_seeds(v)
                else:
                    d[kk] = v
                continue
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                raise SystemExit(f"{path}:{ln}: ongeldige parameternaam '{k}'")
            (cur["set"] if cur is not None else d["set"])[k] = v
    d["variant_order"] = order
    return d


def parse_struct(obj):
    g = lambda *ks: next((obj[k] for k in ks if k in obj), None)  # noqa: E731
    d = dict(name=g("naam", "name"), base=g("basis", "base"), seeds=parse_seeds(g("seeds")) if g("seeds") is not None else None,
             set={k: str(v) for k, v in (g("zet", "set") or {}).items()},
             grid={k: [str(x) for x in v] for k, v in (g("raster", "grid") or {}).items()},
             variants={}, engine=g("engine"), threads=g("threads"), jobs=g("jobs", "parallel"))
    vs = g("varianten", "variants") or {}
    for vn, vd in vs.items():
        vd = dict(vd or {})
        grid = vd.pop("raster", None) or vd.pop("grid", None) or {}
        d["variants"][vn] = dict(set={k: str(v) for k, v in vd.items()}, grid={k: [str(x) for x in v] for k, v in grid.items()})
    d["variant_order"] = list(vs.keys())
    return d


def load_jobfile(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".json":
        with open(path, encoding="utf-8") as f:
            return parse_struct(json.load(f))
    if ext in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            raise SystemExit("YAML-jobbestand vereist PyYAML (python3-yaml); gebruik anders .txt of .json")
        with open(path, encoding="utf-8") as f:
            return parse_struct(yaml.safe_load(f))
    return parse_text(path)


def safe(s):
    s = re.sub(r"[^A-Za-z0-9_.+-]+", "-", str(s)).strip("-")
    return s or "x"


def expand_jobs(d):
    """List of jobs: dict(name, variant, seed, overrides) with overrides = set < variant < grid < seed."""
    variants = [(vn, d["variants"][vn]) for vn in d["variant_order"]] or [(None, dict(set={}, grid={}))]
    jobs = []
    for vn, vd in variants:
        grid = dict(d["grid"])
        grid.update(vd.get("grid", {}))
        keys = list(grid)
        combos = list(itertools.product(*[grid[k] for k in keys])) if keys else [()]
        for combo in combos:
            parts = ([safe(vn)] if vn else []) + [f"{safe(k)}-{safe(v)}" for k, v in zip(keys, combo)]
            vname = "_".join(parts) or "basis"
            ov = dict(d["set"])
            ov.update(vd.get("set", {}))
            ov.update({k: v for k, v in zip(keys, combo)})
            seeds = d["seeds"] if d["seeds"] else [None]
            for sd in seeds:
                o = dict(ov)
                if sd is not None:
                    o["seed"] = str(sd)
                jobs.append(dict(name=vname + (f"_s{sd}" if sd is not None else ""), variant=vname, seed=sd, overrides=o))
    names = [j["name"] for j in jobs]
    dup = sorted({n for n in names if names.count(n) > 1})
    if dup:
        raise SystemExit(f"dubbele jobnamen: {', '.join(dup)}")
    return jobs


def resolve_path(p, jobfile):
    if os.path.isabs(p):
        return p
    for c in (os.path.join(os.path.dirname(os.path.abspath(jobfile)), p), os.path.join(P.CEL, p), os.path.abspath(p)):
        if os.path.exists(c):
            return c
    raise SystemExit(f"basis-ini niet gevonden: {p}")


# ----------------------------------------------------------------------------- scheduler
class Sweep:
    def __init__(self, sdir, st, logf):
        self.sdir = sdir
        self.st = st
        self.logf = logf
        self.stop_req = False
        self.slots = []  # dict(kind, job, proc, t0, step0)
        self.last_status = 0.0
        self.summary_dirty = True

    def log(self, msg):
        P.log(msg, self.logf)

    def save(self):
        P.write_json_atomic(os.path.join(self.sdir, STATE), self.st)

    def on_signal(self, signum, frame):
        self.stop_req = True
        for s in self.slots:
            if s["proc"].poll() is None:
                try:
                    s["proc"].send_signal(signal.SIGTERM)
                except OSError:
                    pass

    def jdir(self, j):
        return os.path.join(self.sdir, j["name"])

    def js(self, j):
        return self.st["state"].setdefault(j["name"], dict(status="wacht", chunks=0, crashes=0, fails=0))

    def target(self, j):
        prm = os.path.join(self.jdir(j), "params.ini")
        if os.path.exists(prm):
            try:
                return int(float(P.read_ini(prm).get("steps")))
            except (TypeError, ValueError):
                pass
        v = j["overrides"].get("steps") or self.st.get("base_steps") or 10000
        return int(float(v))

    def prepare(self):
        """Stop stray engines in job directories, clean half-written files, reset 'loopt' states."""
        strays = {}
        names = {os.path.abspath(self.jdir(j)): j["name"] for j in self.st["jobs"]}
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            cl = P.proc_cmdline(int(d))
            if len(cl) >= 3 and os.path.basename(cl[0]).startswith("oercel") and os.path.abspath(cl[2]) in names:
                strays.setdefault(os.path.abspath(cl[2]), []).append(int(d))
        allp = [p for v in strays.values() for p in v]
        if allp:
            self.log(f"{len(allp)} losse engine-processen van deze sweep gevonden: netjes stoppen (SIGTERM)")
            P.stop_pids(allp)
        for j in self.st["jobs"]:
            s = self.js(j)
            d = self.jdir(j)
            if os.path.isdir(d):
                P.clean_tmp_files(d)
            if s["status"] == "loopt":
                s["status"] = "wacht"
            if s["status"] in ("analyse", "analyse_fout"):
                s["status"] = "klaar"
            if s["status"] == "fout":       # a new start gives failed jobs (and their checkpoints) a new chance
                self.log(f"{j['name']}: eerder mislukt ({s.get('last_error')}); nieuwe poging")
                s.update(status="wacht", fails=0, not_before=0, bad_ckpts=[])
            if s["status"] == "wacht" and os.path.isdir(d) and P.is_finished(d, self.target(j)):
                s["status"] = "klaar"
        self.save()

    def start_engine(self, j):
        st = self.st
        d = self.jdir(j)
        os.makedirs(d, exist_ok=True)
        s = self.js(j)
        restart = None
        cands = P.restart_candidates(d)
        bad = set(s.get("bad_ckpts", []))
        for c in cands:
            key = f"{os.path.basename(c)}:{P.ckpt_step(c)}"
            if key not in bad:
                restart = c
                break
        if cands and restart is None:
            s["status"] = "fout"
            s["last_error"] = "geen bruikbaar checkpoint (niets gewist)"
            self.log(f"{j['name']}: FOUT, geen enkel checkpoint laat zich laden")
            return
        if restart is None and (P.list_snaps(d) or os.path.exists(os.path.join(d, "stats.csv"))):
            P.wipe_engine_outputs(d)
        cmd = P.engine_command(st["engine_path"], os.path.join(self.sdir, "pc_base.ini"), d, j["overrides"],
                               st["threads"], int(st["chunk_min"] * 60), restart=restart)
        eo = os.path.join(d, "pc_engine.out")
        P.trim_file(eo, 5 << 20, 1 << 20)
        with open(eo, "a") as f:
            f.write(f"[{P.stamp()}] {' '.join(cmd)}\n")
        p = P.popen_child(cmd, eo, cwd=P.CEL)
        s["status"] = "loopt"
        s["chunks"] += 1
        s.setdefault("started", P.stamp())
        s0 = P.ckpt_step(restart) if restart else 0
        self.slots.append(dict(kind="engine", job=j, proc=p, t0=time.time(), restart=restart,
                               step0=s0 if s0 is not None else P.current_step(d)))

    def start_analysis(self, j):
        d = self.jdir(j)
        s = self.js(j)
        logp = os.path.join(d, "pc_analyse.log")
        cmd = [P.tools_python(), os.path.join(P.TOOLS, "analyze.py"), d, "--jobs", "1", "--quiet"]
        with open(logp, "a") as f:
            f.write(f"[{P.stamp()}] {' '.join(cmd)}\n")
        p = P.popen_child(cmd, logp, cwd=P.CEL, stdout_too=True, env=P.tool_env())
        s["status"] = "analyse"
        self.slots.append(dict(kind="analyse", job=j, proc=p, t0=time.time()))

    def finish_slot(self, sl):
        j = sl["job"]
        s = self.js(j)
        d = self.jdir(j)
        rc = sl["proc"].returncode
        if sl["kind"] == "analyse":
            if self.stop_req and rc != 0:     # interrupted by --stop / shutdown: analyse again next time
                s["status"] = "klaar"
                return
            if rc == 0 and os.path.exists(os.path.join(d, "checklist.json")):
                s["status"] = "geanalyseerd"
                s["analysed_step"] = P.current_step(d)
                self.summary_dirty = True
            else:
                s["status"] = "analyse_fout"
                s["last_error"] = (P.tail_text(os.path.join(d, "pc_analyse.log"), 400).strip().splitlines() or ["?"])[-1]
                self.log(f"{j['name']}: analyse mislukt: {s['last_error']}")
                self.summary_dirty = True
            return
        if self.stop_req or sl.get("paused"):   # stopped by us (stop request, or disk almost full): no failure
            s["status"] = "wacht"
            return
        step = P.durable_step(d)
        if rc == 0 and (step > sl["step0"] or P.is_finished(d, self.target(j))):
            s["fails"] = 0
            if P.is_finished(d, self.target(j)):
                s["status"] = "klaar"
                s["finished"] = P.stamp()
                self.log(f"{j['name']}: klaar (stap {P.fmt_int(step)})")
            else:
                s["status"] = "wacht"
            return
        s["crashes"] += 1
        s["fails"] = s["fails"] + 1 if step <= sl["step0"] else 1
        rc = rc if rc != 0 else -1000   # clean exit without progress counts as a failure
        tail = P.tail_text(os.path.join(d, "pc_engine.out"), 400).strip().splitlines()
        s["last_error"] = (tail[-1] if tail and not tail[-1].startswith("[") else None) or \
            ("engine stopte zonder voortgang" if rc == -1000 else f"engine gedood door signaal {-rc}" if rc < 0 else f"code {rc}")
        self.log(f"{j['name']}: engine gestopt met code {rc} bij stap {P.fmt_int(step)} (poging {s['fails']}): {s['last_error']}")
        # only a failure that points at the checkpoint itself marks it bad (not a kill, full disk, missing GPU, ...)
        ckpt_fault = bool(CKPT_ERR_RE.search(str(s["last_error"]))) or rc in (-signal.SIGSEGV, -signal.SIGBUS, -signal.SIGABRT)
        if sl.get("restart") and step <= sl["step0"] and time.time() - sl["t0"] < 60 and s["fails"] >= 2 and ckpt_fault:
            s.setdefault("bad_ckpts", []).append(f"{os.path.basename(sl['restart'])}:{P.ckpt_step(sl['restart'])}")
        if s["fails"] >= MAX_FAILURES:
            s["status"] = "fout"
            self.log(f"{j['name']}: FOUT na {s['fails']} mislukte pogingen zonder voortgang; overgeslagen")
        else:
            s["status"] = "wacht"
            s["not_before"] = time.time() + min(300, 15 * 2 ** (s["fails"] - 1))

    def run(self, poll=2.0):
        st = self.st
        st["supervisor_state"] = "loopt"
        st.pop("stopped_by", None)
        try:
            os.unlink(os.path.join(self.sdir, STOP_REQ))
        except OSError:
            pass
        self.prepare()
        nslots = int(st["parallel"])
        self.log(f"sweep {st['name']}: {len(st['jobs'])} jobs, {nslots} tegelijk x {st['threads']} threads, "
                 f"{st['engine']}-engine, chunks van {st['chunk_min']} min")
        while True:
            for sl in list(self.slots):
                if sl["proc"].poll() is not None:
                    self.slots.remove(sl)
                    self.finish_slot(sl)
                    self.save()
            if self.stop_req:
                if not self.slots:
                    break
                time.sleep(0.5)
                continue
            busy = {sl["job"]["name"] for sl in self.slots}
            free = nslots - len(self.slots)
            active = [j for j in st["jobs"] if j["name"] in st["active"]]
            # finished jobs first get their analysis, then unfinished jobs get engine time
            for j in active:
                if free <= 0:
                    break
                if j["name"] not in busy and self.js(j)["status"] == "klaar":
                    self.start_analysis(j)
                    free -= 1
            low = (P.disk_free(self.sdir) or 1 << 62) < float(st.get("min_free_gb", 10)) * 1024 ** 3
            if low and not getattr(self, "_low_logged", False):
                self.log(f"SCHIJF BIJNA VOL (< {st.get('min_free_gb', 10)} GB vrij op de {P.disk_free_detail(self.sdir)[1]}): "
                         f"lopende jobs stoppen netjes "
                         f"(checkpoint), geen nieuwe chunks tot er weer ruimte is")
            if low:
                for sl in self.slots:
                    if sl["kind"] == "engine" and not sl.get("paused") and sl["proc"].poll() is None:
                        sl["paused"] = True
                        try:
                            sl["proc"].send_signal(signal.SIGTERM)
                        except OSError:
                            pass
            self._low_logged = low
            for j in active:
                if free <= 0 or low:
                    break
                s = self.js(j)
                if j["name"] not in busy and s["status"] == "wacht" and time.time() >= s.get("not_before", 0):
                    self.start_engine(j)
                    if s["status"] == "loopt":
                        free -= 1
            self.save()
            todo = [j for j in active if self.js(j)["status"] in ("wacht", "klaar", "loopt", "analyse")]
            if time.time() - self.last_status > 60 or (not todo and not self.slots):
                self.write_reports()
            if not self.slots and not todo:
                break
            t1 = time.time() + poll
            while time.time() < t1 and not self.stop_req:
                time.sleep(0.2)
                if any(sl["proc"].poll() is not None for sl in self.slots):
                    break
        states = [self.js(j)["status"] for j in st["jobs"] if j["name"] in st["active"]]
        st["supervisor_state"] = "gestopt" if self.stop_req else "klaar"
        st["supervisor_end"] = P.stamp()
        if self.stop_req:   # --stop leaves a marker; without it the SIGTERM came from a shutdown -> --hervat resumes
            st["stopped_by"] = "gebruiker" if os.path.exists(os.path.join(self.sdir, STOP_REQ)) else "signaal"
        self.write_reports(force=True)
        self.save()
        if self.stop_req:
            self.log("sweep gestopt op verzoek; hervat met hetzelfde commando")
            return 0
        nf = sum(1 for x in states if x in ("fout", "analyse_fout"))
        self.log(f"sweep klaar: {states.count('geanalyseerd')} geanalyseerd, {nf} mislukt. "
                 f"Samenvatting: {os.path.join(self.sdir, 'SAMENVATTING.md')}")
        return 0 if nf == 0 else 2

    def write_reports(self, force=False):
        self.last_status = time.time()
        try:
            P.write_text_atomic(os.path.join(self.sdir, "STATUS.md"), sweep_status_md(self.sdir, self.st))
            if self.summary_dirty or force:
                md, csv = summary(self.sdir, self.st)
                P.write_text_atomic(os.path.join(self.sdir, "SAMENVATTING.md"), md)
                P.write_text_atomic(os.path.join(self.sdir, "samenvatting.csv"), csv)
                self.summary_dirty = False
        except Exception as e:
            self.log(f"rapport schrijven mislukt: {e!r}")


# ----------------------------------------------------------------------------- reports
CL = {"ja": "J", "deels": "d", "nee": "-"}


def job_metrics(sdir, st, j):
    d = os.path.join(sdir, j["name"])
    a = P.analysis_summary(d) if os.path.exists(os.path.join(d, "checklist.json")) else None
    return a


def rank_key(a):
    return (a["n_ja"], a["n_deels"], a["divisions_confirmed"], a["divisions"], a.get("cat_cells_max", 0),
            a.get("cells_max", 0), a.get("cells_last", 0))


def varying_keys(jobs):
    keys = set()
    for j in jobs:
        keys |= set(j["overrides"])
    keys.discard("seed")
    return sorted(k for k in keys if len({j["overrides"].get(k) for j in jobs}) > 1)


def summary(sdir, st):
    jobs = [j for j in st["jobs"] if j["name"] in st["active"]]
    rows = []
    for j in jobs:
        a = job_metrics(sdir, st, j)
        rows.append((j, a, st["state"].get(j["name"], {})))
    done = [(j, a) for j, a, _ in rows if a is not None]
    vk = varying_keys(jobs)
    L = [f"# Sweep {st['name']} — samenvatting", "",
         f"_bijgewerkt {P.stamp()}_ · basis `{st.get('base_source')}` · {len(jobs)} jobs, {len(done)} geanalyseerd · "
         f"{st['engine']}-engine · {st['parallel']} tegelijk × {st['threads']} threads", "",
         "Checklist-kolom: criteria 1–6 (grens, metabolisme, groei, voortplanting, erfelijkheid, dood); "
         "J = ja, d = deels, - = nee. Rangorde: aantal ja, dan deels, bevestigde delingen, cellen met katalysatoren, "
         "gesloten cellen.", ""]
    # per variant
    byv = {}
    for j, a in done:
        byv.setdefault(j["variant"], []).append((j, a))
    if byv:
        def mean(lst, k):
            return sum(x.get(k, 0) or 0 for x in lst) / len(lst)
        vrows = []
        for vn, lst in byv.items():
            aa = [a for _, a in lst]
            vrows.append((vn, lst, (mean(aa, "n_ja"), mean(aa, "n_deels"), mean(aa, "divisions_confirmed"),
                                    mean(aa, "divisions"), mean(aa, "cat_cells_max"), mean(aa, "cells_max"))))
        vrows.sort(key=lambda r: r[2], reverse=True)
        L += ["## Per variant (gemiddeld over seeds)", "",
              "| rang | variant | instellingen | seeds | ja | deels | delingen (bevestigd) | max cellen | max cellen met katalysator | cellen nu |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for i, (vn, lst, m) in enumerate(vrows, 1):
            ov = lst[0][0]["overrides"]
            inst = " ".join(f"{k}={ov[k]}" for k in vk if k in ov) or "—"
            aa = [a for _, a in lst]
            L.append(f"| {i} | {vn} | {inst} | {len(lst)} | {P.fmt_float(m[0], 1)} | {P.fmt_float(m[1], 1)} | "
                     f"{P.fmt_float(m[3], 1)} ({P.fmt_float(m[2], 1)}) | {P.fmt_float(m[5], 1)} | {P.fmt_float(m[4], 1)} | "
                     f"{P.fmt_float(mean(aa, 'cells_last'), 1)} |")
        L.append("")
    # per job
    done_sorted = sorted(done, key=lambda r: rank_key(r[1]), reverse=True)
    L += ["## Per job", "",
          "| rang | job | checklist | ja | deels | cellen nu | max cellen | met katalysator nu / max | delingen (bevestigd) | max generatie | stap |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, (j, a) in enumerate(done_sorted, 1):
        cl = "".join(CL.get(c["status"], "?") for c in a["checklist"])
        L.append(f"| {i} | {j['name']} | `{cl}` | {a['n_ja']} | {a['n_deels']} | {a.get('cells_last', '?')} | {a.get('cells_max', '?')} | "
                 f"{a.get('cat_cells_last', '?')} / {a.get('cat_cells_max', '?')} | {a['divisions']} ({a['divisions_confirmed']}) | "
                 f"{a.get('max_generation', 0)} | {P.fmt_int(a.get('step_last'))} |")
    rest = [(j, s) for j, a, s in rows if a is None]
    if rest:
        L += ["", "## Nog niet geanalyseerd", ""]
        for j, s in rest:
            L.append(f"- {j['name']}: {P.JOB_LABEL.get(s.get('status', 'wacht'), s.get('status'))}"
                     + (f" — {s['last_error']}" if s.get("last_error") else ""))
    if done_sorted:
        j, a = done_sorted[0]
        L += ["", f"## Beste job: {j['name']}", ""]
        for c in a["checklist"]:
            L.append(f"- {c['id']}. {c['naam']}: **{c['status']}** — {c['samenvatting']}")
    L.append("")
    # csv
    keys = ["job", "variant", "seed"] + vk + ["n_ja", "n_deels"] + [f"c{i}" for i in range(1, 7)] + \
           ["cells_last", "cells_max", "cat_cells_last", "cat_cells_max", "divisions", "divisions_confirmed",
            "max_generation", "fusions", "step_last", "status"]
    C = [",".join(keys)]
    for j, a, s in rows:
        vals = [j["name"], j["variant"], "" if j["seed"] is None else str(j["seed"])] + [j["overrides"].get(k, "") for k in vk]
        if a:
            cl = {c["id"]: c["status"] for c in a["checklist"]}
            vals += [a["n_ja"], a["n_deels"]] + [cl.get(i, "") for i in range(1, 7)] + \
                    [a.get(k, "") for k in ("cells_last", "cells_max", "cat_cells_last", "cat_cells_max", "divisions",
                                            "divisions_confirmed", "max_generation", "fusions", "step_last")]
        else:
            vals += [""] * 17
        vals.append(s.get("status", "wacht"))
        C.append(",".join(str(v) for v in vals))
    return "\n".join(L), "\n".join(C) + "\n"


def sweep_status_md(sdir, st):
    jobs = [j for j in st["jobs"] if j["name"] in st["active"]]
    cnt = {}
    tot_t = tot_c = 0
    running = []
    for j in jobs:
        s = st["state"].get(j["name"], {}).get("status", "wacht")
        cnt[s] = cnt.get(s, 0) + 1
        d = os.path.join(sdir, j["name"])
        cur = P.current_step(d) if os.path.isdir(d) else 0
        try:
            tgt = int(float(P.read_ini(os.path.join(d, "params.ini")).get("steps")))
        except (OSError, TypeError, ValueError):
            tgt = int(float(j["overrides"].get("steps") or st.get("base_steps") or 10000))
        tot_t += tgt
        tot_c += min(cur, tgt)
        if s == "loopt":
            running.append(f"{j['name']} {P.fmt_float(100.0 * cur / max(1, tgt), 0)} %")
    holder = P.lock_holder(sdir)
    L = [f"# Sweep {st['name']}", "", f"_bijgewerkt {P.stamp()}_", "",
         f"- supervisor: " + ("onderbroken door een stopsignaal (afsluiten van WSL/Windows?); hervatten: zie onder"
                              if st.get("supervisor_state") == "gestopt" and st.get("stopped_by") == "signaal" and not holder
                              else f"{st['supervisor_state']} ({st.get('supervisor_end', '')})"
                              if st.get("supervisor_state") in ("klaar", "gestopt") and not holder
                              else (f"loopt (pid {holder})" if holder else "draait niet (hervatten: zie onder)")),
         f"- jobs: {len(jobs)} — " + ", ".join(f"{v} {P.JOB_LABEL.get(k, k)}" for k, v in sorted(cnt.items())),
         f"- voortgang (stappen): {P.fmt_float(100.0 * tot_c / max(1, tot_t), 1)} %",
         f"- {st['parallel']} tegelijk × {st['threads']} threads, {st['engine']}-engine",
         f"- bezig: {', '.join(running[:20]) + (' ...' if len(running) > 20 else '') if running else '—'}",
         "", "Ranglijst: `SAMENVATTING.md`. Hervatten (vanuit de hoofdmap van de repo): `"
         + P.shown_cmd("sweep.py", f"--hervat {st['name']} --achtergrond{P.runs_arg(sdir)}", for_file=True) + "`", ""]
    fouten = [(j["name"], st["state"][j["name"]].get("last_error")) for j in jobs
              if st["state"].get(j["name"], {}).get("status") in ("fout", "analyse_fout")]
    if fouten:
        L += ["## Mislukt", ""] + [f"- {n}: {e}" for n, e in fouten] + [""]
    return "\n".join(L)


# ----------------------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("jobbestand", nargs="?", help="jobbestand (.txt, .json of .yaml)")
    ap.add_argument("--hervat", metavar="NAAM", help="sweep hervatten met de opgeslagen definitie")
    ap.add_argument("--stop", metavar="NAAM", help="draaiende sweep netjes stoppen")
    ap.add_argument("--samenvatting", metavar="NAAM", help="alleen SAMENVATTING.md opnieuw maken")
    ap.add_argument("--heranalyse", action="store_true", help="alle klare jobs opnieuw analyseren (bijv. na een tools-update)")
    ap.add_argument("--naam", help="sweepnaam (overschrijft 'naam' uit het jobbestand)")
    ap.add_argument("--jobs", type=int, default=None, help="aantal jobs tegelijk (standaard (CPU's - reserve) / threads)")
    ap.add_argument("--threads", type=int, default=None, help="threads per job (standaard 2)")
    ap.add_argument("--reserve", type=int, default=2, help="CPU's vrijhouden (standaard 2)")
    ap.add_argument("--engine", default=None, help="cpu (standaard) | gpu | auto | pad naar binary")
    ap.add_argument("--chunk-min", type=float, default=None, help="minuten per engine-chunk (standaard 60)")
    ap.add_argument("--runs-dir", default=None)
    ap.add_argument("--achtergrond", action="store_true", help="los van de terminal draaien")
    ap.add_argument("--proef", action="store_true", help="alleen joblijst en commando's tonen, niets starten")
    ap.add_argument("--poll", type=float, default=2.0, help=argparse.SUPPRESS)
    ap.add_argument("--_bg", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if a._bg:
        P.LOG_STDOUT = False
    runs = P.runs_dir(a.runs_dir)

    if a.stop:
        sdir = os.path.join(runs, a.stop)
        pid = P.lock_holder(sdir) if os.path.isdir(sdir) else None
        if not pid or pid == "?":
            print(f"{a.stop}: geen draaiende sweep")
            return 0
        try:
            with open(os.path.join(sdir, STOP_REQ), "w") as f:
                f.write(f"{P.stamp()} pid {os.getpid()}\n")
        except OSError:
            pass
        os.kill(int(pid), signal.SIGTERM)
        print(f"{a.stop}: stopsignaal naar pid {pid}; jobs schrijven een checkpoint ...")
        t0 = time.time()
        while P.pid_alive(int(pid)) and time.time() - t0 < 600:
            time.sleep(1)
        print(f"{a.stop}: {'gestopt' if not P.pid_alive(int(pid)) else 'nog bezig'}")
        return 0
    if a.samenvatting:
        sdir = os.path.join(runs, a.samenvatting)
        st = P.read_json(os.path.join(sdir, STATE))
        if st is None:
            raise SystemExit(f"geen sweep {a.samenvatting}")
        md, csv = summary(sdir, st)
        P.write_text_atomic(os.path.join(sdir, "SAMENVATTING.md"), md)
        P.write_text_atomic(os.path.join(sdir, "samenvatting.csv"), csv)
        print(md)
        return 0

    n_added = 0
    if a.hervat:
        name = a.hervat
        sdir = os.path.join(runs, name)
        st = P.read_json(os.path.join(sdir, STATE))
        if st is None:
            raise SystemExit(f"geen sweep {name} in {runs}")
    else:
        if not a.jobbestand:
            ap.error("geef een jobbestand, of --hervat/--stop/--samenvatting NAAM")
        d = load_jobfile(a.jobbestand)
        name = safe(a.naam or d["name"] or os.path.splitext(os.path.basename(a.jobbestand))[0])
        if not d["base"]:
            raise SystemExit("jobbestand mist 'basis = <ini>'")
        base = resolve_path(d["base"], a.jobbestand)
        base_kv = P.read_ini(base)
        jobs = expand_jobs(d)
        for j in jobs:
            bad = sorted(set(j["overrides"]) & P.RESERVED_KEYS)
            if bad:
                raise SystemExit(f"job {j['name']}: {', '.join(bad)} regelt sweep.py zelf (threads: --threads)")
        if base_kv.get("restart"):
            raise SystemExit("de basis-ini heeft 'restart' gezet; sweep-jobs starten altijd vanaf een soep")
        sdir = os.path.join(runs, name)
        st = P.read_json(os.path.join(sdir, STATE))
        engine_choice = a.engine or d["engine"] or "cpu"
        if st is None:
            label, binary = P.resolve_engine(engine_choice, "sweep")
            keys = set(base_kv)
            for j in jobs:
                keys |= set(j["overrides"])
            miss = P.unsupported_keys(binary, keys)
            if miss:
                raise SystemExit(f"de {label}-engine ({binary}) kent deze parameters niet: {', '.join(miss)}.\n"
                                 f"Gebruik --engine PAD met een engine die ze wel kent.")
            thr = a.threads or (int(d["threads"]) if d["threads"] else 2)
            par = a.jobs or (int(d["jobs"]) if d["jobs"] else max(1, (P.cpu_count() - a.reserve) // thr))
            if label == "gpu" and not (a.jobs or d["jobs"]) and par > GPU_PARALLEL_DEFAULT:
                par = GPU_PARALLEL_DEFAULT
                print(f"GPU-engine: standaard {par} jobs tegelijk (ze delen één GPU); anders --jobs N")
            st = dict(kind="sweep", version=VERSION, name=name, created=P.stamp(), jobfile_source=os.path.abspath(a.jobbestand),
                      base_source=os.path.relpath(base, P.CEL), base_steps=base_kv.get("steps"), engine=label,
                      engine_path=binary, engine_sha1=P.file_sha1(binary), threads=thr, parallel=par,
                      chunk_min=a.chunk_min or 60, jobs=jobs, active=[j["name"] for j in jobs], state={})
            if a.proef:
                print(f"sweep {name}: {len(jobs)} jobs, {par} tegelijk x {thr} threads, {label}-engine {binary}")
                for j in jobs:
                    print(f"  {j['name']:<40s} " + " ".join(f"{k}={v}" for k, v in j["overrides"].items()))
                print("voorbeeldcommando (eerste chunk):")
                print("  " + " ".join(P.engine_command(binary, base, os.path.join(sdir, jobs[0]["name"]), jobs[0]["overrides"],
                                                       thr, int(st["chunk_min"] * 60))))
                return 0
            os.makedirs(sdir, exist_ok=True)
            shutil.copyfile(base, os.path.join(sdir, "pc_base.ini"))
            shutil.copyfile(a.jobbestand, os.path.join(sdir, "pc_jobs" + (os.path.splitext(a.jobbestand)[1] or ".txt")))
        else:
            # resume / extend: same definition for jobs that already exist, new jobs are added
            old = {j["name"]: j for j in st["jobs"]}
            if os.path.exists(os.path.join(sdir, "pc_base.ini")) and P.read_ini(os.path.join(sdir, "pc_base.ini")) != base_kv:
                raise SystemExit(f"de basis-ini {base} is veranderd sinds de start van sweep {name}; "
                                 f"kies een nieuwe naam (--naam) voor een nieuw experiment")
            conflicts = [j["name"] for j in jobs if j["name"] in old and old[j["name"]]["overrides"] != j["overrides"]]
            if conflicts:
                raise SystemExit(f"jobs met dezelfde naam maar andere parameters: {', '.join(conflicts)}; kies een nieuwe sweepnaam")
            added = [j for j in jobs if j["name"] not in old]
            n_added = len(added)
            st["jobs"] += added
            st["active"] = [j["name"] for j in jobs]
            if added:
                print(f"{name}: {len(added)} nieuwe jobs toegevoegd")
            if a.proef:
                print(f"sweep {name} bestaat al: {len(st['jobs'])} jobs, actief {len(st['active'])}")
                return 0
    if a.threads:
        st["threads"] = a.threads
    if a.jobs:
        st["parallel"] = a.jobs
    if a.chunk_min:
        st["chunk_min"] = a.chunk_min
    if a.heranalyse:
        for n, s in st.get("state", {}).items():
            if s.get("status") in ("geanalyseerd", "analyse_fout"):
                s["status"] = "klaar"
    if st["engine"] == "cpu":
        P.ensure_built("cpu")
    if not os.path.exists(st["engine_path"]):
        raise SystemExit(f"engine ontbreekt: {st['engine_path']} (draai pc/setup_wsl.sh)")
    sha = P.file_sha1(st["engine_path"])
    if sha != st.get("engine_sha1"):
        st.setdefault("engine_changes", []).append(dict(time=P.stamp(), old=st.get("engine_sha1"), new=sha))
        st["engine_sha1"] = sha
        print("LET OP: de engine-binary is veranderd sinds de start van deze sweep (genoteerd in pc_sweep.json)")

    holder = P.lock_holder(sdir)
    if holder:
        print(f"{name}: sweep draait al (pid {holder}); status: {P.shown_path(os.path.join(sdir, 'STATUS.md'))}")
        changed = [o for o, v in (("--jobs", a.jobs), ("--threads", a.threads), ("--chunk-min", a.chunk_min))
                   if v] + (["--heranalyse"] if a.heranalyse else []) + ([f"{n_added} nieuwe jobs"] if n_added else [])
        if changed:
            print(f"  NIET TOEGEPAST: {', '.join(changed)}. Een draaiende sweep neemt geen wijzigingen aan; "
                  f"eerst: {P.shown_cmd('sweep.py', '--stop ' + name + P.runs_arg(sdir))}   en dan dit commando opnieuw.")
            return 1
        return 0
    if P.on_windows_drive(sdir):
        print("LET OP: de repo staat op de Windows-schijf (/mnt/...): alles is daar veel trager. "
              "Beter: de repo in je Linux-thuismap (~) clonen; zie pc/setup_wsl.sh.")
    n_other, t_other = P.engine_threads_in_use(exclude_dirs=[sdir])
    if n_other and t_other + int(st["parallel"]) * int(st["threads"]) > P.cpu_count():
        print(f"LET OP: er draaien al {n_other} engine-processen met samen {t_other} threads; deze sweep wil "
              f"{st['parallel']} x {st['threads']} threads op {P.cpu_count()} CPU's: overboekt, alles wordt trager. "
              f"Overweeg --jobs {max(1, (P.cpu_count() - t_other - 2) // max(1, int(st['threads'])))}.")
    P.write_json_atomic(os.path.join(sdir, STATE), st)
    if a.achtergrond:
        argv = ["--hervat", name] + (["--runs-dir", a.runs_dir] if a.runs_dir else []) + ["--poll", str(a.poll)]
        pid = P.detach(os.path.abspath(__file__), argv, os.path.join(sdir, "pc_supervisor.out"))
        time.sleep(1.5)
        print(f"{name}: sweep gestart op de achtergrond (pid {pid}); {len(st['active'])} jobs, "
              f"{st['parallel']} tegelijk x {st['threads']} threads")
        print(f"  voortgang: {P.shown_cmd('status.py')}   ·   ranglijst: {os.path.join(sdir, 'SAMENVATTING.md')}")
        return 0
    try:
        lock = P.DirLock(sdir).acquire()
    except P.AlreadyRunning as e:
        print(f"{name}: sweep draait al (pid {e.pid})")
        return 0
    logf = open(os.path.join(sdir, "pc_sweep.log"), "a")
    sw = Sweep(sdir, st, logf)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, sw.on_signal)
    try:
        rc = sw.run(poll=a.poll)
    finally:
        lock.release()
        logf.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
