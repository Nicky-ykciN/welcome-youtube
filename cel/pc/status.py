#!/usr/bin/env python3
"""Oercel: one-screen Dutch overview of all sweeps and long runs (and the machine).

  pc/status.py              overzicht van alles in cel/runs/
  pc/status.py NAAM ...     alleen deze runs/sweeps, met de volledige levens-checklist
  pc/status.py --kort       één regel per run/sweep

Reads only files (pc_longrun.json, pc_sweep.json, STATUS.md inputs, stats.csv, log.txt, analysis
JSON); it never starts or stops anything.  Unfinished runs/sweeps whose supervisor is not running
are listed with the exact command to resume them.
"""
import argparse
import glob
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pclib as P  # noqa: E402


def machine_line(runs):
    la = P.loadavg()
    parts = [f"{P.cpu_count()} CPU's, belasting {P.fmt_float(la[0], 1)}"]
    try:
        with open("/proc/meminfo") as f:
            mi = {l.split(":")[0]: int(l.split()[1]) for l in f}
        parts.append(f"geheugen vrij {P.fmt_float(mi['MemAvailable'] / 1048576, 1)} / {P.fmt_float(mi['MemTotal'] / 1048576, 1)} GB")
    except (OSError, KeyError, ValueError):
        pass
    g = P.gpu_info()
    if g:
        for x in g:
            parts.append(f"GPU {x['name']}: {x['util']} % bezet, {P.fmt_float(float(x['mem_used']) / 1024, 1)}/"
                         f"{P.fmt_float(float(x['mem_total']) / 1024, 0)} GB, {x['temp']} °C")
    else:
        parts.append("geen werkende GPU (nvidia-smi)")
    fr = P.disk_free(runs)
    if fr is not None:
        parts.append(f"schijf vrij {P.fmt_bytes(fr)}")
    return " · ".join(parts)


def engine_procs():
    n = 0
    for d in glob.glob("/proc/[0-9]*"):
        cl = P.proc_cmdline(os.path.basename(d))
        if cl and os.path.basename(cl[0]).startswith("oercel") and len(cl) >= 3:
            n += 1
    return n


def longrun_block(rd, st, full):
    name = os.path.basename(rd)
    holder = P.lock_holder(rd)
    tgt = int(st.get("steps", 0))
    cur = P.current_step(rd)
    status = st.get("status", "?")
    if holder and status not in ("klaar", "fout"):
        status = "loopt"
    elif status == "loopt":
        status = "ONDERBROKEN"
    sp = st.get("last_speed")
    eta = f", klaar over ~{P.fmt_dur((tgt - cur) / sp)}" if sp and holder and cur < tgt else ""
    a = st.get("analysis") or {}
    cl = "".join({"ja": "J", "deels": "d", "nee": "-"}.get(c["status"], "?") for c in a.get("checklist", []))
    line = (f"  {name:<22s} {status:<11s} {st.get('engine', '?').upper():<4s} stap {P.fmt_int(cur)}/{P.fmt_int(tgt)} "
            f"({P.fmt_float(100.0 * cur / max(1, tgt), 1)} %)"
            + (f", {P.fmt_int(sp)} st/s" if sp else "") + eta)
    out = [line]
    if a:
        out.append(f"      cellen {a.get('cells_last', '?')} (met katalysator {a.get('cat_cells_last', '?')}), "
                   f"delingen {a.get('divisions', 0)} ({a.get('divisions_confirmed', 0)} bevestigd), checklist [{cl}] "
                   f"(analyse t/m stap {P.fmt_int(st.get('last_analysis_step'))}, "
                   f"{P.fmt_dur(time.time() - st.get('last_analysis_time', time.time()))} geleden)")
    else:
        out.append("      nog geen analyse")
    if st.get("crashes"):
        lc = st.get("last_crash") or {}
        out.append(f"      {st['crashes']} crash(es); laatste {lc.get('time', '?')}: {lc.get('error', '')[:120]}")
    if full and a.get("checklist"):
        for c in a["checklist"]:
            out.append(f"        {c['id']}. {c['naam']:<24s} {c['status']:<6s} {c['samenvatting'][:150]}")
    imgs = st.get("images", {})
    if full and any(imgs.values()):
        for k in ("micro", "goodsell", "timelapse"):
            if imgs.get(k):
                out.append(f"      beeld {k}: {os.path.relpath(imgs[k][-1], P.CEL)}")
    out.append(f"      details: {os.path.relpath(os.path.join(rd, 'STATUS.md'), P.CEL)}")
    resume = None
    if not holder and st.get("status") not in ("klaar",):
        resume = f"python3 pc/longrun.py {name} --achtergrond" + _runs_arg(rd)
    return out, resume, status


def _runs_arg(d):
    parent = os.path.dirname(os.path.abspath(d))
    return "" if parent == P.runs_dir() else f" --runs-dir {os.path.relpath(parent, P.CEL)}"


def sweep_block(sd, st, full):
    name = os.path.basename(sd)
    holder = P.lock_holder(sd)
    jobs = [j for j in st["jobs"] if j["name"] in st.get("active", [])]
    cnt = {}
    for j in jobs:
        s = st.get("state", {}).get(j["name"], {}).get("status", "wacht")
        cnt[s] = cnt.get(s, 0) + 1
    unfinished = any(s in ("wacht", "loopt", "klaar", "analyse") for s in cnt)
    status = "loopt" if holder else ("ONDERBROKEN" if unfinished else "klaar")
    out = [f"  {name:<22s} {status:<11s} {len(jobs)} jobs: " + ", ".join(f"{v} {k}" for k, v in sorted(cnt.items()))
           + f"  ({st.get('parallel')} tegelijk x {st.get('threads')} threads, {st.get('engine')})"]
    best = []
    for j in jobs:
        d = os.path.join(sd, j["name"])
        if os.path.exists(os.path.join(d, "checklist.json")):
            a = P.analysis_summary(d, with_cells=full)
            if a:
                best.append((a["n_ja"], a["n_deels"], a["divisions_confirmed"], a["divisions"], j["name"], a))
    best.sort(reverse=True)
    for b in best[: (5 if full else 3)]:
        a = b[5]
        cl = "".join({"ja": "J", "deels": "d", "nee": "-"}.get(c["status"], "?") for c in a["checklist"])
        extra = f", cellen max {a.get('cells_max', '?')} (met kat. {a.get('cat_cells_max', '?')})" if full else ""
        out.append(f"      {b[4]:<34s} [{cl}] {a['n_ja']} ja, {a['n_deels']} deels, delingen {a['divisions']} "
                   f"({a['divisions_confirmed']} bev.){extra}")
    fails = [(j["name"], st["state"][j["name"]].get("last_error")) for j in jobs
             if st.get("state", {}).get(j["name"], {}).get("status") in ("fout", "analyse_fout")]
    for n, e in fails[:5]:
        out.append(f"      MISLUKT {n}: {str(e)[:120]}")
    out.append(f"      ranglijst: {os.path.relpath(os.path.join(sd, 'SAMENVATTING.md'), P.CEL)}")
    resume = f"python3 pc/sweep.py --hervat {name} --achtergrond" + _runs_arg(sd) if (not holder and unfinished) else None
    return out, resume, status


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("namen", nargs="*", help="alleen deze runs/sweeps (volledige details)")
    ap.add_argument("--runs-dir", default=None)
    ap.add_argument("--kort", action="store_true")
    a = ap.parse_args()
    runs = P.runs_dir(a.runs_dir)
    full = bool(a.namen) and not a.kort
    print(f"Oercel-status  {P.stamp()}")
    print("  " + machine_line(runs))
    print(f"  engine-processen actief: {engine_procs()}   (CPU-engine: {'ok' if os.path.exists(P.ENGINE_CPU) else 'ONTBREEKT'}, "
          f"GPU-engine: {'ok' if os.path.exists(P.ENGINE_GPU) else 'niet gebouwd'})")
    lr, sw = [], []
    for d in sorted(glob.glob(os.path.join(runs, "*"))):
        if a.namen and os.path.basename(d) not in a.namen:
            continue
        st = P.read_json(os.path.join(d, "pc_longrun.json"))
        if st:
            lr.append((d, st))
            continue
        st = P.read_json(os.path.join(d, "pc_sweep.json"))
        if st:
            sw.append((d, st))
    resumes = []
    print()
    print(f"LANGE RUNS ({len(lr)})")
    if not lr:
        print("  (geen)  start er een met: python3 pc/longrun.py NAAM --ini <ini> --set ... --achtergrond")
    for d, st in sorted(lr, key=lambda x: x[1].get("created", "")):
        try:
            out, res, _ = longrun_block(d, st, full)
        except Exception as e:
            out, res = [f"  {os.path.basename(d)}: kan status niet lezen ({e!r})"], None
        print("\n".join(out[:1] if a.kort else out))
        if res:
            resumes.append(res)
    print()
    print(f"SWEEPS ({len(sw)})")
    if not sw:
        print("  (geen)  start er een met: python3 pc/sweep.py pc/voorbeelden/<jobbestand> --achtergrond")
    for d, st in sorted(sw, key=lambda x: x[1].get("created", "")):
        try:
            out, res, _ = sweep_block(d, st, full)
        except Exception as e:
            out, res = [f"  {os.path.basename(d)}: kan status niet lezen ({e!r})"], None
        print("\n".join(out[:1] if a.kort else out))
        if res:
            resumes.append(res)
    if resumes:
        print()
        print("ONAF EN NIET ACTIEF (bijv. na een herstart van de pc) — hervatten met:")
        for r in resumes:
            print("  " + r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
