#!/usr/bin/env python3
"""Oercel: het experimentplan (cel/pc/plan.txt) uitvoeren.  Wordt gebruikt door start.sh en stop.sh.

  python3 cel/pc/plan.py start        plan toepassen: nieuw -> starten, onderbroken -> hervatten,
                                      draait/klaar -> niets; daarna andere onderbroken runs/sweeps hervatten
  python3 cel/pc/plan.py lijst        per planregel: wat het is en hoe het ervoor staat (verandert niets)
  python3 cel/pc/plan.py proef        planregels controleren (ini's, parameters, jobbestanden) zonder te starten
  python3 cel/pc/plan.py stop         alle draaiende runs en sweeps netjes stoppen (checkpoint); voor stop.sh
  opties: --plan PAD (ander planbestand), --droog (bij start: alleen tonen wat er zou gebeuren)

Planbestand (tekst, één actie per regel, '#' = commentaar, '\\' aan het eind = regel gaat door):

  longrun.py NAAM --engine gpu --ini engine/params/membranes.ini --set L=512 steps=50000000 ...
  sweep.py pc/voorbeelden/leven_scan.txt --threads 2 --reserve 20
  als engine/params/production.ini bestaat: longrun.py ...      (alleen als dat bestand er is)
  anders: longrun.py ...                                         (alleen als de 'als'-regel erboven niet gold)

Paden zijn relatief aan cel/ (of absoluut); '--achtergrond' wordt automatisch toegevoegd.

Wat 'start' per regel doet:
  * run/sweep bestaat nog niet            -> starten met precies deze regel;
  * draait al                             -> niets;
  * klaar                                 -> niets (een sweep krijgt wel nieuwe jobs als het jobbestand er
                                             meer heeft; een lange run gaat verder als het plan meer stappen wil);
  * onderbroken (herstart van de pc, stroomstoring, crash, stop.sh) -> hervatten vanaf het laatste checkpoint
    met de opgeslagen instellingen (pc/longrun.py NAAM / pc/sweep.py --hervat NAAM);
  * bewust gestopt met --stop (niet via stop.sh) -> blijft staan (dat was een keuze van iemand);
  * lange run op de GPU terwijl de GPU (nog) niet werkt -> wacht (wordt bij een volgende start opnieuw geprobeerd).
Een bestaande run verandert nooit van parameters: past het plan niet meer bij een run, dan zegt 'start' dat.
Nothing here touches the physics (SPEC section 0): it only starts, resumes and stops pc/longrun.py and pc/sweep.py.
"""
import argparse
import glob
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pclib as P  # noqa: E402

PLAN_DEFAULT = os.environ.get("OERCEL_PLAN") or os.path.join(P.PC, "plan.txt")
STOP_MARK = "pc_gestopt_door_stop_sh"      # written by `plan.py stop` (stop.sh): start.sh resumes these
SCRIPTS = {"longrun.py": "longrun", "sweep.py": "sweep"}
LONGRUN_VALUE_OPTS = ["--ini", "--steps", "--engine", "--van-ckpt", "--threads", "--chunk-min", "--analyse-uur",
                      "--analyse-jobs", "--keep-recent", "--max-stride", "--max-snap-gb", "--keep-ckpt",
                      "--div-window", "--images-keep", "--width", "--min-vrij-gb", "--runs-dir", "--beelden-dir",
                      "--poll", "--backoff"]
LONGRUN_FLAGS = ["--forceer-engine", "--adopteer", "--geen-beelden", "--achtergrond", "--stop", "--analyseer-nu", "--_bg"]
# settings a resumed run may take over from the plan line (physics never changes)
LONGRUN_RESUME_OPTS = ["--threads", "--chunk-min", "--analyse-uur", "--analyse-jobs", "--keep-recent", "--max-stride",
                       "--max-snap-gb", "--keep-ckpt", "--div-window", "--images-keep", "--width", "--min-vrij-gb"]
SWEEP_VALUE_OPTS = ["--naam", "--jobs", "--threads", "--reserve", "--engine", "--chunk-min", "--runs-dir", "--poll",
                    "--hervat", "--stop", "--samenvatting"]
SWEEP_FLAGS = ["--achtergrond", "--heranalyse", "--proef", "--_bg"]


class PlanError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise PlanError(message)


def resolve(p, plan_path=None):
    """A path from the plan: absolute, or relative to cel/ (also accepted: relative to the plan file or to
    the repository root, e.g. cel/pc/...)."""
    if os.path.isabs(p):
        return p
    cands = [os.path.join(P.CEL, p)]
    if plan_path:
        cands.append(os.path.join(os.path.dirname(os.path.abspath(plan_path)), p))
    cands.append(os.path.join(P.REPO, p))
    for c in cands:
        if os.path.exists(c):
            return os.path.abspath(c)
    return os.path.abspath(cands[0])


def rel_cel(p):
    try:
        r = os.path.relpath(os.path.abspath(p), P.CEL)
    except ValueError:
        return p
    return p if r.startswith("..") else r


# ----------------------------------------------------------------------------- reading the plan
def logical_lines(path):
    """(line number, text) with comments removed and '\\' continuations joined."""
    with open(path, encoding="utf-8") as f:
        raw = f.read().splitlines()
    out, buf, start = [], "", None
    for i, line in enumerate(raw, 1):
        line = re.sub(r"(^|\s)#.*$", "", line).rstrip()
        if start is None:
            start = i
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        if buf.strip():
            out.append((start, " ".join(buf.split())))
        buf, start = "", None
    if buf.strip():
        out.append((start, " ".join(buf.split())))
    return out


def parse_longrun_args(args):
    ap = _Parser(add_help=False, prog="longrun.py")
    ap.add_argument("naam")
    for o in LONGRUN_VALUE_OPTS:
        ap.add_argument(o)
    ap.add_argument("--set", nargs="*", default=[])
    for o in LONGRUN_FLAGS:
        ap.add_argument(o, action="store_true")
    a, rest = ap.parse_known_args(args)
    if rest:
        raise PlanError(f"onbekende opties voor longrun.py: {' '.join(rest)}")
    for o in ("stop", "analyseer_nu", "_bg", "adopteer", "runs_dir"):
        if getattr(a, o):
            raise PlanError(f"--{o.replace('_', '-')} hoort niet in het plan")
    return a


def parse_sweep_args(args):
    ap = _Parser(add_help=False, prog="sweep.py")
    ap.add_argument("jobbestand", nargs="?")
    for o in SWEEP_VALUE_OPTS:
        ap.add_argument(o)
    for o in SWEEP_FLAGS:
        ap.add_argument(o, action="store_true")
    a, rest = ap.parse_known_args(args)
    if rest:
        raise PlanError(f"onbekende opties voor sweep.py: {' '.join(rest)}")
    for o in ("hervat", "stop", "samenvatting", "proef", "_bg", "runs_dir"):
        if getattr(a, o):
            raise PlanError(f"--{o.replace('_', '-')} hoort niet in het plan (start.sh hervat zelf)")
    if not a.jobbestand:
        raise PlanError("sweep.py zonder jobbestand")
    return a


def opt_list(args, names):
    """The given value options (with their values) from a token list, in order."""
    out, i = [], 0
    while i < len(args):
        t = args[i]
        k = t.split("=", 1)[0]
        if k in names:
            if "=" in t:
                out.append(t)
            elif i + 1 < len(args):
                out += [t, args[i + 1]]
                i += 1
        i += 1
    return out


def with_abs_paths(args, value_opts, path_opts=(), new_positional=None):
    """Copy of a token list with the first positional argument replaced by new_positional and the values
    of path_opts (e.g. --ini) made absolute (the scripts run from cel/, the plan may name paths relative
    to cel/ or to the repository root)."""
    out, i, pos_done = [], 0, new_positional is None
    while i < len(args):
        t = args[i]
        k = t.split("=", 1)[0]
        if k in value_opts:
            if "=" in t:
                v = t.split("=", 1)[1]
                out.append(f"{k}={resolve(v)}" if k in path_opts else t)
            else:
                out.append(t)
                if i + 1 < len(args):
                    out.append(resolve(args[i + 1]) if k in path_opts else args[i + 1])
                    i += 1
        elif not t.startswith("-") and not pos_done:
            out.append(new_positional)
            pos_done = True
        else:
            out.append(t)
        i += 1
    return out


def read_plan(path):
    """Plan entries: dict(line, text, kind, args, active, cond, name, ...)."""
    entries = []
    prev = None     # truth value of the 'als' line directly above (None: there is none)
    for ln, text in logical_lines(path):
        cond = None
        m = re.match(r"^als\s+(niet\s+)?(\S+)\s+bestaat\s*:\s*(.*)$", text, re.I)
        if m:
            p = resolve(m.group(2), path)
            exists = os.path.exists(p)
            neg = bool(m.group(1))
            active = exists != neg
            cond = dict(kind="als", path=m.group(2), exists=exists, neg=neg)
            prev, action = active, m.group(3)
        else:
            m = re.match(r"^anders\s*:\s*(.*)$", text, re.I)
            if m:
                if prev is None:
                    raise PlanError(f"{path}:{ln}: 'anders:' zonder 'als ... bestaat:' direct erboven")
                active, cond = (not prev), dict(kind="anders")
                prev, action = None, m.group(1)
            else:
                prev, active, action = None, True, text
        try:
            tok = shlex.split(action)
        except ValueError as e:
            raise PlanError(f"{path}:{ln}: {e}")
        if tok and os.path.basename(tok[0]).startswith("python"):
            tok = tok[1:]
        if not tok:
            raise PlanError(f"{path}:{ln}: lege actie")
        script = os.path.basename(tok[0])
        if script not in SCRIPTS:
            raise PlanError(f"{path}:{ln}: verwacht longrun.py of sweep.py, niet '{tok[0]}'")
        e = dict(line=ln, text=action, kind=SCRIPTS[script], args=tok[1:], active=active, cond=cond)
        try:
            if e["kind"] == "longrun":
                a = parse_longrun_args(e["args"])
                e["name"] = a.naam.strip("/").split("/")[-1]
                e["a"] = a
                try:
                    P.parse_kv_list(a.set or [])
                except ValueError as err:
                    raise PlanError(f"--set: {err}")
            else:
                a = parse_sweep_args(e["args"])
                e["a"] = a
                e["jobfile"] = resolve(a.jobbestand, path)
                e["name"] = None
                if os.path.exists(e["jobfile"]):
                    import sweep as SW
                    d = SW.load_jobfile(e["jobfile"])
                    e["name"] = SW.safe(a.naam or d["name"] or os.path.splitext(os.path.basename(e["jobfile"]))[0])
                    e["jobnames"] = [j["name"] for j in SW.expand_jobs(d)]
                elif e["active"]:
                    raise PlanError(f"jobbestand niet gevonden: {a.jobbestand}")
        except PlanError as err:
            raise PlanError(f"{path}:{ln}: {err}")
        except SystemExit as err:      # sweep.py's own parser of the job file
            raise PlanError(f"{path}:{ln}: jobbestand: {err}")
        entries.append(e)
    return entries


def plan_target(e):
    """Target step of a longrun line: --steps, steps= in --set, or steps in the ini."""
    a = e["a"]
    if a.steps is not None:
        return int(float(a.steps))
    kv = P.parse_kv_list(a.set or [])
    if "steps" in kv:
        return int(float(kv["steps"]))
    if a.ini:
        ini = resolve(a.ini)
        if os.path.exists(ini):
            return int(float(P.read_ini(ini).get("steps", 10000)))
    return None


# ----------------------------------------------------------------------------- state of runs and sweeps
def longrun_state(rd, plan_steps=None):
    """(state, info): nieuw | draait | klaar | bewust | onderbroken | geen_longrun."""
    st = P.read_json(os.path.join(rd, "pc_longrun.json"))
    if st is None:
        if os.path.isdir(rd) and (P.list_snaps(rd) or os.path.exists(os.path.join(rd, "params.ini"))):
            return "geen_longrun", None
        return "nieuw", None
    holder = P.lock_holder(rd)
    if holder:
        return "draait", st
    raw = st.get("status")
    if raw == "klaar" and not (plan_steps and plan_steps > int(st.get("steps", 0))):
        return "klaar", st
    if raw == "gestopt" and st.get("stopped_by") == "gebruiker" and not os.path.exists(os.path.join(rd, STOP_MARK)):
        return "bewust", st
    return "onderbroken", st


def sweep_state(sd, jobnames=None):
    """(state, info): nieuw | draait | klaar | bewust | onderbroken | uitbreiden."""
    st = P.read_json(os.path.join(sd, "pc_sweep.json"))
    if st is None:
        return "nieuw", None
    if P.lock_holder(sd):
        return "draait", st
    known = {j["name"] for j in st.get("jobs", [])}
    if jobnames and any(n not in known for n in jobnames):
        return "uitbreiden", st
    active = [j["name"] for j in st.get("jobs", []) if j["name"] in st.get("active", [])]
    states = [st.get("state", {}).get(n, {}).get("status", "wacht") for n in active]
    unfinished = any(s in ("wacht", "loopt", "klaar", "analyse") for s in states)
    if not unfinished:
        return "klaar", st
    user_stop = st.get("supervisor_state") == "gestopt" and st.get("stopped_by") == "gebruiker"
    if user_stop and not os.path.exists(os.path.join(sd, STOP_MARK)):
        return "bewust", st
    return "onderbroken", st


def sweep_counts(st):
    active = [j["name"] for j in st.get("jobs", []) if j["name"] in st.get("active", [])]
    cnt = {}
    for n in active:
        s = st.get("state", {}).get(n, {}).get("status", "wacht")
        cnt[s] = cnt.get(s, 0) + 1
    return ", ".join(f"{v} {P.JOB_LABEL.get(k, k)}" for k, v in sorted(cnt.items())) or "geen jobs"


def clear_mark(d):
    try:
        os.unlink(os.path.join(d, STOP_MARK))
    except OSError:
        pass


# ----------------------------------------------------------------------------- running pc scripts
def run_script(script, args, dry=False, timeout=900):
    """Run pc/<script> args (from cel/); returns (rc, output)."""
    cmd = [sys.executable, os.path.join(P.PC, script)] + list(args)
    if dry:
        return 0, "[droog] " + " ".join(shlex.quote(c) for c in cmd[1:])
    try:
        p = subprocess.run(cmd, cwd=P.CEL, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return 124, f"{script} reageerde niet binnen {timeout} s"
    return p.returncode, (p.stdout + p.stderr).strip()


def indent(text, pre="      "):
    return "\n".join(pre + l for l in text.splitlines() if l.strip())


GPU_RE = re.compile(r"GPU-engine (niet bruikbaar|ontbreekt)|nvidia-smi|CUDA", re.I)


def gpu_ok_for(st):
    if st.get("engine") != "gpu":
        return True, ""
    return P.gpu_engine_check(st.get("engine_path"))


def plan_differs(e, st):
    """Text when an existing run was started with other physics than the plan line now says."""
    a = e["a"]
    notes = []
    if a.ini:
        want = rel_cel(resolve(a.ini))
        have = st.get("ini_source", "")
        if have and want != have:
            notes.append(f"gestart met {have}, het plan noemt nu {want}")
    if a.set is not None:
        ov = P.parse_kv_list(a.set or [])
        ov.pop("steps", None)
        have = dict(st.get("overrides") or {})
        if ov != have and not notes:
            diff = sorted(k for k in set(ov) | set(have) if ov.get(k) != have.get(k))
            notes.append("andere --set-waarden in het plan: " + ", ".join(diff[:8]) + (" ..." if len(diff) > 8 else ""))
    if not notes:
        return None
    return ("LET OP: " + "; ".join(notes) + ". Een bestaande run verandert nooit van parameters: hij gaat door met "
            "zijn eigen instellingen. Voor een run volgens de nieuwe regel: geef die regel een nieuwe naam.")


def do_longrun(e, dry):
    a = e["a"]
    name = e["name"]
    rd = os.path.join(P.runs_dir(), name)
    tgt = plan_target(e)
    state, st = longrun_state(rd, tgt)
    head = f"  regel {e['line']:<3d} {name} (lange run)"
    if state == "geen_longrun":
        return f"{head}: FOUT — {P.shown_path(rd)} bestaat al maar is geen pc/longrun.py-run; kies een andere naam", "fout"
    if state == "draait":
        msg = f"{head}: draait al (stap {P.fmt_int(P.current_step(rd))} van {P.fmt_int(st.get('steps'))}, {st.get('engine', '?').upper()})"
        if tgt and tgt > int(st.get("steps", 0)):
            msg += (f"\n      het plan wil {P.fmt_int(tgt)} stappen: dat wordt toegepast bij de volgende hervatting "
                    f"(na stop.sh + start.sh)")
        d = plan_differs(e, st)
        clear_mark(rd)
        return msg + (f"\n      {d}" if d else ""), "draait"
    if state == "klaar":
        clear_mark(rd)
        return f"{head}: klaar ({P.fmt_int(st.get('steps'))} stappen; zie {P.shown_path(os.path.join(rd, 'STATUS.md'))})", "klaar"
    if state == "bewust":
        return (f"{head}: bewust gestopt met --stop; blijft staan. Toch verder: "
                f"{P.shown_cmd('longrun.py', name + ' --achtergrond')}"), "bewust"
    if state == "nieuw":
        if a.ini and not os.path.exists(resolve(a.ini)):
            return f"{head}: FOUT — ini niet gevonden: {a.ini}", "fout"
        args = with_abs_paths(e["args"], LONGRUN_VALUE_OPTS, ("--ini", "--van-ckpt")) + ([] if a.achtergrond else ["--achtergrond"])
        rc, out = run_script("longrun.py", args, dry)
        if rc != 0 and GPU_RE.search(out):
            return f"{head}: WACHT OP GPU — nog niet gestart\n{indent(out)}", "wacht_gpu"
        if rc != 0:
            return f"{head}: FOUT bij starten (code {rc})\n{indent(out)}", "fout"
        src = ""
        if e["cond"]:
            c = e["cond"] if e["cond"]["kind"] == "als" else None
            src = (f" [{c['path']} {'bestaat' if c['exists'] else 'bestaat niet'}]" if c
                   else " [terugvalregel: de 'als'-regel erboven gold niet]")
        return f"{head}: NIEUW GESTART{src}\n{indent(out)}", "gestart"
    # onderbroken (or klaar with a higher target in the plan)
    ok, why = gpu_ok_for(st)
    if not ok:
        return f"{head}: WACHT OP GPU — niet hervat: {why}", "wacht_gpu"
    args = [name] + opt_list(e["args"], LONGRUN_RESUME_OPTS)
    if tgt and tgt > int(st.get("steps", 0)):
        args += ["--steps", str(tgt)]
    if "--geen-beelden" in e["args"]:
        args.append("--geen-beelden")
    args.append("--achtergrond")
    rc, out = run_script("longrun.py", args, dry)
    if rc != 0:
        return f"{head}: FOUT bij hervatten (code {rc})\n{indent(out)}", "fout"
    if not dry:
        clear_mark(rd)
    why = {"fout": "was gestopt na fouten", "gestopt": "was gestopt (stop.sh of afsluiten)"}.get(st.get("status"), "was onderbroken")
    d = plan_differs(e, st)
    return (f"{head}: HERVAT ({why}; stap {P.fmt_int(P.current_step(rd))} van {P.fmt_int(max(int(st.get('steps', 0)), tgt or 0))})"
            f"\n{indent(out)}" + (f"\n      {d}" if d else "")), "hervat"


def do_sweep(e, dry):
    a = e["a"]
    name = e["name"]
    head = f"  regel {e['line']:<3d} {name} (sweep)"
    if not name:
        return f"{head}: FOUT — jobbestand niet gevonden: {a.jobbestand}", "fout"
    sd = os.path.join(P.runs_dir(), name)
    state, st = sweep_state(sd, e.get("jobnames"))
    if state == "draait":
        clear_mark(sd)
        msg = f"{head}: draait al ({sweep_counts(st)})"
        known = {j["name"] for j in st.get("jobs", [])}
        extra = [n for n in e.get("jobnames", []) if n not in known]
        if extra:
            msg += f"\n      het jobbestand heeft {len(extra)} nieuwe jobs: die komen erbij na stop.sh + start.sh"
        return msg, "draait"
    if state == "klaar":
        clear_mark(sd)
        return f"{head}: klaar ({sweep_counts(st)}; ranglijst {P.shown_path(os.path.join(sd, 'SAMENVATTING.md'))})", "klaar"
    if state == "bewust":
        return (f"{head}: bewust gestopt met --stop; blijft staan. Toch verder: "
                f"{P.shown_cmd('sweep.py', '--hervat ' + name + ' --achtergrond')}"), "bewust"
    if state in ("nieuw", "uitbreiden"):
        args = with_abs_paths(e["args"], SWEEP_VALUE_OPTS, new_positional=e["jobfile"])
        if not a.achtergrond:
            args.append("--achtergrond")
        rc, out = run_script("sweep.py", args, dry)
        if rc != 0:
            res = f"{head}: FOUT bij {'starten' if state == 'nieuw' else 'uitbreiden'} (code {rc})\n{indent(out)}"
            if state == "uitbreiden" and sweep_state(sd)[0] == "onderbroken":
                rc2, out2 = run_script("sweep.py", ["--hervat", name, "--achtergrond"], dry)
                res += (f"\n      bestaande jobs hervat:\n{indent(out2, '        ')}" if rc2 == 0
                        else f"\n      hervatten lukte ook niet (code {rc2}):\n{indent(out2, '        ')}")
            return res, "fout"
        if not dry:
            clear_mark(sd)
        return f"{head}: {'NIEUW GESTART' if state == 'nieuw' else 'UITGEBREID met nieuwe jobs'}\n{indent(out)}", "gestart"
    rc, out = run_script("sweep.py", ["--hervat", name, "--achtergrond"], dry)
    if rc != 0:
        return f"{head}: FOUT bij hervatten (code {rc})\n{indent(out)}", "fout"
    if not dry:
        clear_mark(sd)
    return f"{head}: HERVAT ({sweep_counts(st)})\n{indent(out)}", "hervat"


def resume_others(names, dry):
    """Runs and sweeps outside the plan: resume what was interrupted (as status.py --hervat), plus
    everything stop.sh stopped.  Returns printed lines."""
    import status as S
    out = []
    for d in sorted(glob.glob(os.path.join(P.runs_dir(), "*"))):
        name = os.path.basename(d)
        if name in names:
            continue
        st = P.read_json(os.path.join(d, "pc_longrun.json"))
        kind = "longrun" if st else None
        if st is None:
            st = P.read_json(os.path.join(d, "pc_sweep.json"))
            kind = "sweep" if st else None
        if kind is None:
            continue
        mark = os.path.exists(os.path.join(d, STOP_MARK))
        try:
            blk = S.longrun_block(d, st, False) if kind == "longrun" else S.sweep_block(d, st, False)
        except Exception as e:     # a broken state file must not stop the rest
            out.append(f"  {name}: status niet leesbaar ({e!r})")
            continue
        _, resume, _, auto = blk
        if resume is None:
            if mark:
                clear_mark(d)
            continue
        if not (auto or mark):
            out.append(f"  {name}: bewust gestopt; blijft staan (verder: {P.shown_cmd(resume[0], resume[1])})")
            continue
        if kind == "longrun":
            ok, why = gpu_ok_for(st)
            if not ok:
                out.append(f"  {name}: WACHT OP GPU — niet hervat: {why}")
                continue
        rc, txt = run_script(resume[0], resume[1].split(), dry)
        if rc == 0:
            if not dry:
                clear_mark(d)
            out.append(f"  {name}: HERVAT\n{indent(txt)}")
        else:
            out.append(f"  {name}: FOUT bij hervatten (code {rc})\n{indent(txt)}")
    return out


# ----------------------------------------------------------------------------- commands
def cmd_start(plan, dry):
    print(f"Experimentplan: {P.shown_path(plan)}")
    try:
        entries = read_plan(plan)
    except PlanError as e:
        print(f"  FOUT in het plan: {e}")
        print("  (er is niets gestart; andere onderbroken runs worden wel hervat)")
        entries = None
    counts = {}
    names = set()
    if entries is not None:
        for e in entries:
            if e.get("name"):
                names.add(e["name"])
        if not any(e["active"] for e in entries):
            print("  (geen actieve regels)")
        for e in entries:
            if not e["active"]:
                continue
            try:
                msg, res = (do_longrun if e["kind"] == "longrun" else do_sweep)(e, dry)
            except Exception as ex:     # one bad line must not stop the others
                msg, res = f"  regel {e['line']}: FOUT {ex!r}", "fout"
            print(msg)
            counts[res] = counts.get(res, 0) + 1
            sys.stdout.flush()
    other = resume_others(names, dry)
    if other:
        print("Overige runs en sweeps (niet in het plan):")
        print("\n".join(other))
    n_eng, n_thr = P.engine_threads_in_use()
    if not dry:
        time.sleep(0.5)
        n_eng, n_thr = P.engine_threads_in_use()
    print(f"Engine-processen nu: {n_eng} met samen {n_thr} threads (van {P.cpu_count()} CPU's)")
    return 1 if counts.get("fout") or entries is None else 0


def cmd_lijst(plan):
    print(f"Experimentplan: {P.shown_path(plan)}")
    entries = read_plan(plan)
    for e in entries:
        cond = ""
        if e["cond"] and e["cond"]["kind"] == "als":
            c = e["cond"]
            cond = f"  [als {c['path']} {'niet ' if c['neg'] else ''}bestaat: {'ja' if c['exists'] else 'nee'}]"
        elif e["cond"]:
            cond = "  [anders]"
        if not e["active"]:
            print(f"  regel {e['line']:<3d} {e.get('name') or '?'}: geldt nu niet{cond}")
            continue
        if e["kind"] == "longrun":
            rd = os.path.join(P.runs_dir(), e["name"])
            state, st = longrun_state(rd, plan_target(e))
            extra = f", stap {P.fmt_int(P.current_step(rd))} van {P.fmt_int(st.get('steps'))}" if st else ""
            print(f"  regel {e['line']:<3d} {e['name']} (lange run): {state}{extra}{cond}")
        else:
            sd = os.path.join(P.runs_dir(), e["name"] or "?")
            state, st = sweep_state(sd, e.get("jobnames"))
            extra = f" ({sweep_counts(st)})" if st else f" ({len(e.get('jobnames', []))} jobs)"
            print(f"  regel {e['line']:<3d} {e['name']} (sweep): {state}{extra}{cond}")
    return 0


def cmd_proef(plan):
    """Check every line (also the ones that do not apply now) without starting anything."""
    import tempfile
    print(f"Experimentplan controleren: {P.shown_path(plan)}")
    try:
        entries = read_plan(plan)
    except PlanError as e:
        print(f"  FOUT: {e}")
        return 1
    bad = 0
    engines = [("cpu", P.ENGINE_CPU)] + ([("gpu", P.ENGINE_GPU)] if os.path.exists(P.ENGINE_GPU) else [])
    for e in entries:
        tag = f"  regel {e['line']:<3d} {e.get('name') or '?'}" + ("" if e["active"] else " (geldt nu niet)")
        if e["kind"] == "longrun":
            a = e["a"]
            ini = resolve(a.ini) if a.ini else None
            if ini is None:
                print(f"{tag}: alleen hervatten (geen --ini)")
                continue
            if not os.path.exists(ini):
                if e["active"]:
                    print(f"{tag}: FOUT — ini niet gevonden: {a.ini}")
                    bad += 1
                else:
                    print(f"{tag}: ini {a.ini} bestaat (nog) niet — wordt pas gebruikt als hij er is")
                continue
            base = P.read_ini(ini)
            try:
                ov = P.parse_kv_list(a.set or [])
            except ValueError as ex:
                print(f"{tag}: FOUT in --set: {ex}")
                bad += 1
                continue
            res = sorted(set(ov) & P.RESERVED_KEYS)
            if res:
                print(f"{tag}: FOUT — {', '.join(res)} regelt longrun.py zelf")
                bad += 1
            for lab, b in engines:
                miss = P.unsupported_keys(b, set(base) | set(ov))
                if miss:
                    print(f"{tag}: FOUT — de {lab}-engine kent deze parameters niet: {', '.join(miss)}")
                    bad += 1
            # let the CPU engine itself accept every value (tiny box, 10 steps, in a temporary directory)
            ov2 = {k: v for k, v in ov.items() if k not in ("L", "steps", "snap_every", "stats_every", "ckpt_every", "log_every")}
            tmp = tempfile.mkdtemp(prefix="oercel_plan_proef_")
            try:
                cmd = [P.ENGINE_CPU, ini, os.path.join(tmp, "r")] + [f"{k}={v}" for k, v in ov2.items()] + \
                      ["L=24", "steps=10", "snap_every=0", "stats_every=0", "ckpt_every=0", "log_every=0", "threads=1"]
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
                ok = r.returncode == 0
                err = (r.stderr + r.stdout).strip().splitlines()
            except (OSError, subprocess.SubprocessError) as ex:
                ok, err = False, [repr(ex)]
            finally:
                import shutil
                shutil.rmtree(tmp, ignore_errors=True)
            kv = dict(base)
            kv.update(ov)
            summ = ", ".join(f"{k}={kv[k]}" for k in ("init", "L", "steps", "snap_every", "chem", "p_syn_a", "p_syn_b",
                                                        "feed", "p_feed", "feed_cap", "a_T_N", "stir_A") if k in kv)
            if ok:
                print(f"{tag}: OK — {rel_cel(ini)} + {len(ov)} overschrijvingen; engine accepteert alles (proef L=24, 10 stappen)\n      {summ}")
            else:
                print(f"{tag}: FOUT — de CPU-engine weigert deze instellingen: {err[-1] if err else '?'}")
                bad += 1
        else:
            if not os.path.exists(e["jobfile"]):
                print(f"{tag}: {'FOUT — ' if e['active'] else ''}jobbestand niet gevonden: {e['a'].jobbestand}")
                bad += 1 if e["active"] else 0
                continue
            args = with_abs_paths(e["args"], SWEEP_VALUE_OPTS, new_positional=e["jobfile"])
            args = [t for t in args if t != "--achtergrond"] + ["--proef"]
            rc, out = run_script("sweep.py", args, timeout=300)
            lines = out.splitlines()
            if rc == 0:
                print(f"{tag}: OK — {lines[0] if lines else ''} ({len(e.get('jobnames', []))} jobs)")
            else:
                print(f"{tag}: FOUT\n{indent(out)}")
                bad += 1
    print(f"== {bad} fout(en) ==")
    return 1 if bad else 0


def cmd_stop():
    """Stop every running long run and sweep cleanly (their own --stop), in parallel.  Each gets the
    marker STOP_MARK, so the next start.sh resumes it (a plain --stop stays stopped)."""
    runs = P.runs_dir()
    procs = []
    for d in sorted(glob.glob(os.path.join(runs, "*"))):
        name = os.path.basename(d)
        if os.path.exists(os.path.join(d, "pc_longrun.json")):
            kind = "longrun"
        elif os.path.exists(os.path.join(d, "pc_sweep.json")):
            kind = "sweep"
        else:
            continue
        holder = P.lock_holder(d)
        strays = P.engine_pids_for(d) if (kind == "longrun" and not holder) else []
        if not holder and not strays:
            continue
        if holder:
            try:
                with open(os.path.join(d, STOP_MARK), "w") as f:
                    f.write(f"{P.stamp()} gestopt door stop.sh (start.sh hervat dit)\n")
            except OSError:
                pass
        args = [name, "--stop"] if kind == "longrun" else ["--stop", name]
        cmd = [sys.executable, os.path.join(P.PC, f"{kind}.py")] + args
        p = subprocess.Popen(cmd, cwd=P.CEL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             stdin=subprocess.DEVNULL)
        procs.append((name, kind, p))
        print(f"  {name} ({'lange run' if kind == 'longrun' else 'sweep'}): stopsignaal gegeven")
        sys.stdout.flush()
    if not procs:
        print("  er draaide niets")
        return 0
    print("  wachten tot alle engines een checkpoint hebben geschreven ...")
    sys.stdout.flush()
    rc = 0
    for name, _kind, p in procs:
        out, _ = p.communicate()
        last = [l for l in out.strip().splitlines() if l.strip()]
        print(f"  {name}: {last[-1] if last else 'klaar'}")
        if P.lock_holder(os.path.join(runs, name)):
            rc = 1
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("actie", choices=["start", "lijst", "proef", "stop"])
    ap.add_argument("--plan", default=PLAN_DEFAULT)
    ap.add_argument("--droog", action="store_true", help="bij start: niets starten, alleen tonen")
    a = ap.parse_args()
    if a.actie == "stop":
        return cmd_stop()
    if not os.path.exists(a.plan):
        print(f"geen planbestand: {a.plan}")
        return 1 if a.actie != "start" else 0
    if a.actie == "start":
        return cmd_start(a.plan, a.droog)
    try:
        return cmd_lijst(a.plan) if a.actie == "lijst" else cmd_proef(a.plan)
    except PlanError as e:
        print(f"FOUT in het plan: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
