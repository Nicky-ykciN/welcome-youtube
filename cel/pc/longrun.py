#!/usr/bin/env python3
"""Oercel: supervisor for one long production run (GPU engine, CPU engine as fallback).

  nieuwe run:  pc/longrun.py NAAM --ini notes/membranen/teamA_membranes.ini --set L=256 steps=50000000 [opties]
  hervatten:   pc/longrun.py NAAM                (na crash, reboot of stop: zelfde run gaat verder)
  achtergrond: pc/longrun.py NAAM ... --achtergrond   (los van terminal/Claude-sessie; log in runs/NAAM/pc_supervisor.log)
  stoppen:     pc/longrun.py NAAM --stop         (engine stopt netjes met checkpoint)
  nu analyse:  pc/longrun.py NAAM --analyseer-nu (vraagt de draaiende supervisor om meteen te analyseren)

What it does
  * runs the engine in chunks (engine option walltime) with restart=runs/NAAM/ckpt.bin; the engine's
    restart is bit-for-bit exact, so chunks, crashes, kill -9 and reboots do not change the result;
  * a crash (non-zero exit, killed engine) is retried with back-off; a checkpoint that cannot be
    loaded falls back to the previous kept copy (ckpt_<step>.bin);
  * if the supervisor itself is killed, the engine receives SIGTERM (PR_SET_PDEATHSIG) and stops
    with a checkpoint; a stray engine still writing into the run directory is stopped on start;
  * every --analyse-uur hours: tools/analyze.py, then images into beelden/NAAM/ (micrograph of the
    dish, Goodsell picture of the most interesting cell, time-lapse when a division exists);
  * keeps disk use bounded: older snapshots are thinned on a power-of-two schedule after they have
    been analysed; snapshots around detected divisions, the first snapshot and everything newer than
    the last analysis or checkpoint are never removed; only the newest checkpoints are kept;
  * writes runs/NAAM/STATUS.md (Dutch) and pc_longrun.json (state).
Nothing here changes the physics (SPEC section 0): it only starts, stops and restarts the engine.
"""
import argparse
import math
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pclib as P  # noqa: E402

STATE = "pc_longrun.json"
SUPLOG = "pc_supervisor.log"
ENGOUT = "pc_engine.out"
VERSION = 1

# settings that may be changed on every (re)start; physics (ini + overrides) may not
SETTINGS_DEFAULTS = dict(threads=None, chunk_min=60, analyse_uur=2.0, analyse_jobs=8, keep_recent=200,
                         max_stride=64, max_snap_gb=100.0, keep_ckpt=3, div_window=10, images_keep=4,
                         width=2000, render=True, poll_s=5.0, max_failures=6)


# ----------------------------------------------------------------------------- thinning
def snap_interval(rundir, snaps):
    prm = {}
    try:
        prm = P.read_ini(os.path.join(rundir, "params.ini"))
    except (OSError, ValueError):
        pass
    try:
        se = int(float(prm.get("snap_every", 0)))
    except ValueError:
        se = 0
    if se > 0:
        return se
    if len(snaps) >= 2:
        d = [b[0] - a[0] for a, b in zip(snaps, snaps[1:]) if b[0] > a[0]]
        return min(d) if d else 1
    return 1


def thinning_plan(snaps, snap_every, analysed_upto, ckpt_step, protected, keep_recent, max_stride):
    """Return the list of (step, path) to delete.

    Kept: the first snapshot; every snapshot newer than the analysed range or than the latest
    checkpoint; protected steps (division windows); the newest keep_recent analysed snapshots;
    older ones on a stride that doubles with age (2, 4, 8, ... up to max_stride snapshot intervals).
    The kept set of a given snapshot only shrinks as the run gets older, so a snapshot that was
    removed is never "needed" again by the schedule."""
    if not snaps or analysed_upto is None:
        return []
    cand = [(s, p) for s, p in snaps if s <= analysed_upto and (ckpt_step is None or s < ckpt_step)]
    if len(cand) <= 1:
        return []
    newest = cand[-1][0]
    base = max(1, keep_recent) * snap_every
    first = snaps[0][0]
    prot = set(protected)
    out = []
    for s, p in cand:
        if s == first or s in prot:
            continue
        age = newest - s
        if age < base:
            continue
        level = int(math.floor(math.log2(age / base))) + 1
        stride = min(2 ** level, max_stride)
        if (s // snap_every) % stride != 0:
            out.append((s, p))
    return out


def protected_steps(snaps, division_steps, window):
    """Steps of the `window` snapshots before and after every division (by position in the list)."""
    steps = [s for s, _ in snaps]
    out = set()
    import bisect
    for d in division_steps:
        i = bisect.bisect_left(steps, d)
        for j in range(max(0, i - window), min(len(steps), i + window + 1)):
            out.add(steps[j])
    return out


# ----------------------------------------------------------------------------- supervisor
class Supervisor:
    def __init__(self, rundir, state, logf):
        self.rundir = rundir
        self.st = state
        self.logf = logf
        self.stop_req = False
        self.analyse_req = False
        self.proc = None
        self.pipe_thread = None
        self.lock = threading.Lock()
        self.samples = []  # (wall time, step)

    # -- helpers
    def log(self, msg):
        P.log(msg, self.logf)

    def save(self):
        with self.lock:
            try:
                P.write_json_atomic(os.path.join(self.rundir, STATE), self.st)
            except OSError as e:
                self.log(f"status opslaan mislukt: {e!r}")

    @property
    def cfg(self):
        return self.st["settings"]

    def target(self):
        return int(self.st["steps"])

    # -- signals
    def on_signal(self, signum, frame):
        if signum == signal.SIGUSR1:
            self.analyse_req = True
            return
        self.stop_req = True
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.send_signal(signal.SIGTERM)
            except OSError:
                pass

    # -- engine
    def engine_cmd(self, restart):
        st = self.st
        ini = os.path.join(self.rundir, "pc_base.ini")
        ov = dict(st["overrides"])
        ov["steps"] = str(st["steps"])
        return P.engine_command(st["engine_path"], ini, self.rundir, ov, self.cfg["threads"],
                                int(self.cfg["chunk_min"] * 60), restart=restart)

    def pick_restart(self):
        """(checkpoint, key): the newest checkpoint not marked bad; ('', None) when checkpoints exist
        but all are marked bad; (None, None) when there is none (fresh start or --van-ckpt)."""
        bad = set(self.st.get("bad_ckpts", []))
        cands = P.restart_candidates(self.rundir)
        for c in cands:
            key = f"{os.path.basename(c)}:{P.ckpt_step(c)}:{os.path.getsize(c) if os.path.exists(c) else 0}"
            if key not in bad:
                return c, key
        if cands:
            return "", None
        if self.st.get("from_ckpt"):
            return self.st["from_ckpt"], None
        return None, None

    def sample(self):
        s = P.current_step(self.rundir)
        t = time.time()
        self.samples.append((t, s))
        self.samples = [x for x in self.samples if t - x[0] < 3600 * 3][-2000:]
        return s

    def speed(self, window=1800):
        """steps per second over the last `window` seconds of engine running (chunk gaps excluded)."""
        if len(self.samples) < 2:
            return self.st.get("last_speed")
        t1, s1 = self.samples[-1]
        pts = [x for x in self.samples if t1 - x[0] <= window]
        if len(pts) < 2:
            pts = self.samples[-2:]
        t0, s0 = pts[0]
        if t1 - t0 < 20 or s1 <= s0:
            return self.st.get("last_speed")
        v = (s1 - s0) / (t1 - t0)
        self.st["last_speed"] = v
        return v

    def stop_strays(self):
        pids = P.engine_pids_for(self.rundir)
        if pids:
            self.log(f"engine-proces(sen) {pids} schrijven nog in {self.rundir}: netjes stoppen (SIGTERM)")
            P.stop_pids(pids)

    def prune_ckpts(self):
        copies = P.list_ckpt_copies(self.rundir)
        keep = set(c for _, c in copies[-max(1, self.cfg["keep_ckpt"]):])
        # one copy before every division (to branch from just before it)
        for d in self.st.get("division_steps", []):
            before = [c for s, c in copies if s < d]
            if before:
                keep.add(before[-1])
        if self.st.get("from_ckpt"):
            keep.add(self.st["from_ckpt"])
        for _, c in copies:
            if c not in keep:
                try:
                    os.unlink(c)
                except OSError:
                    pass

    # -- main loop
    def run(self):
        st = self.st
        rd = self.rundir
        self.stop_strays()
        n = P.clean_tmp_files(rd)
        if n:
            self.log(f"{n} half geschreven bestand(en) van een afgebroken engine opgeruimd")
        if not P.restart_candidates(rd) and not st.get("from_ckpt"):
            if P.list_snaps(rd) or os.path.exists(os.path.join(rd, "stats.csv")):
                n = P.wipe_engine_outputs(rd)
                self.log(f"geen checkpoint: run begint opnieuw vanaf de soep ({n} oude bestanden verwijderd)")
        st["status"] = "loopt"
        st["supervisor_pid"] = os.getpid()
        st["supervisor_started"] = P.stamp()
        self.save()
        fails = 0
        last_fail_step = None
        last_status = 0.0
        self.sample()
        while not self.stop_req:
            if P.is_finished(rd, self.target()):
                break
            restart, key = self.pick_restart()
            if restart == "":
                st["status"] = "fout"
                self.log("geen enkel checkpoint laat zich laden (alle pogingen mislukt): supervisor stopt, er wordt NIETS "
                         "gewist. Zie pc_engine.out en log.txt; 'bad_ckpts' in pc_longrun.json leegmaken om opnieuw te proberen.")
                break
            if restart is None and st.get("chunks", 0) > 0:
                # the engine ran before but died before its first checkpoint: start over from the soup
                n = P.wipe_engine_outputs(rd)
                self.log(f"geen checkpoint na eerdere poging: opnieuw vanaf de soep ({n} bestanden opgeruimd)")
            cmd = self.engine_cmd(restart)
            step0 = P.current_step(rd)
            self.log(f"chunk {st.get('chunks', 0) + 1}: {'herstart van ' + os.path.basename(restart) if restart else 'start vanaf willekeurige soep'}"
                     f" (stap {P.fmt_int(P.ckpt_step(restart) if restart and P.ckpt_step(restart) is not None else step0)})")
            P.trim_file(os.path.join(rd, ENGOUT))
            t_start = time.time()
            with open(os.path.join(rd, ENGOUT), "a") as f:
                f.write(f"[{P.stamp()}] {' '.join(cmd)}\n")
            self.proc = P.popen_child(cmd, os.path.join(rd, ENGOUT), cwd=P.CEL)
            st["engine_pid"] = self.proc.pid
            st["chunks"] = st.get("chunks", 0) + 1
            if restart and restart == st.get("from_ckpt"):
                st["from_ckpt_used"] = True
            self.save()
            while self.proc.poll() is None:
                self._sleep(self.cfg["poll_s"])
                self.sample()
                if time.time() - last_status > 60:
                    self.prune_ckpts()
                    self.write_status()
                    last_status = time.time()
                self.maybe_pipeline()
            rc = self.proc.returncode
            self.proc = None
            st["engine_pid"] = None
            step1 = self.sample()
            dur = time.time() - t_start
            if self.stop_req:
                break
            if rc == 0:
                fails = 0
                if not P.is_finished(rd, self.target()):
                    self.log(f"chunk klaar na {P.fmt_dur(dur)}: stap {P.fmt_int(step1)}")
                continue
            # crash
            fails = fails + 1 if (last_fail_step is None or step1 <= last_fail_step) else 1
            last_fail_step = step1
            st["crashes"] = st.get("crashes", 0) + 1
            tail = P.tail_text(os.path.join(rd, ENGOUT), 600).strip().splitlines()
            err = (tail[-1] if tail and not tail[-1].startswith("[") else None) or P.log_state(rd)["last_error"] \
                or (f"engine gedood door signaal {-rc}" if rc is not None and rc < 0 else "?")
            st["last_crash"] = dict(time=P.stamp(), rc=rc, step=step1, error=str(err)[:300])
            self.log(f"ENGINE GESTOPT met code {rc} na {P.fmt_dur(dur)} bij stap {P.fmt_int(step1)} "
                     f"(poging {fails}): {str(err)[:200]}")
            if restart and key and dur < 60 and step1 <= step0 and fails >= 2:
                st.setdefault("bad_ckpts", []).append(key)
                self.log(f"checkpoint {os.path.basename(restart)} lijkt onbruikbaar: volgende keer een oudere kopie")
            self.save()
            if fails >= self.cfg["max_failures"]:
                st["status"] = "fout"
                self.log("te vaak achter elkaar mislukt zonder voortgang: supervisor stopt. Zie pc_engine.out en log.txt.")
                break
            self._sleep(min(300, 10 * 2 ** (fails - 1)))
        # finish
        if self.stop_req:
            st["status"] = "gestopt"
            self.log("gestopt op verzoek (checkpoint geschreven); hervat met hetzelfde commando")
        elif st.get("status") != "fout":
            st["status"] = "klaar"
            st["finished"] = P.stamp()
            self.log(f"run klaar bij stap {P.fmt_int(P.current_step(rd))}")
            self.wait_pipeline()
            sn = P.list_snaps(rd)
            if sn and sn[-1][0] > (st.get("last_analysis_step") or -1):
                self.pipeline(final=True)
        self.wait_pipeline()
        self.prune_ckpts()
        self.save()
        self.write_status()
        return 0 if st["status"] in ("klaar", "gestopt") else 2

    def _sleep(self, sec):
        t1 = time.time() + sec
        while time.time() < t1 and not self.stop_req:
            time.sleep(min(1.0, t1 - time.time()) if t1 > time.time() else 0)
            if self.proc is not None and self.proc.poll() is not None:
                return

    # -- analysis / images / thinning
    def maybe_pipeline(self):
        if self.pipe_thread is not None and self.pipe_thread.is_alive():
            return
        iv = float(self.cfg["analyse_uur"])
        due = iv > 0 and time.time() - self.st.get("last_analysis_time", 0) >= iv * 3600
        if not (due or self.analyse_req):
            return
        snaps = P.list_snaps(self.rundir)
        if len(snaps) < 2 or (snaps[-1][0] <= self.st.get("last_analysis_step", -1) and not self.analyse_req):
            return
        self.analyse_req = False
        self.pipe_thread = threading.Thread(target=self.pipeline, daemon=True)
        self.pipe_thread.start()

    def wait_pipeline(self):
        if self.pipe_thread is not None:
            self.pipe_thread.join()
            self.pipe_thread = None

    def run_tool(self, args, what, timeout=None):
        cmd = [P.tools_python()] + args
        logp = os.path.join(self.rundir, "pc_tools.log")
        P.trim_file(logp, 5 << 20, 1 << 20)
        with open(logp, "ab") as f:
            f.write(f"\n[{P.stamp()}] {' '.join(cmd)}\n".encode())
            f.flush()
            p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd=P.CEL,
                                 preexec_fn=P._set_pdeathsig)
            try:
                rc = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                p.kill()
                rc = -999
        if rc != 0:
            self.log(f"{what} mislukt (code {rc}); zie {os.path.relpath(logp, P.CEL)}")
        return rc == 0

    def pipeline(self, final=False):
        st = self.st
        rd = self.rundir
        t0 = time.time()
        try:
            if not P.list_snaps(rd):
                return
            ok = self.run_tool([os.path.join(P.TOOLS, "analyze.py"), rd, "--jobs", str(self.cfg["analyse_jobs"]), "--quiet"],
                               "analyse")
            summ = P.analysis_summary(rd) if ok else None
            if summ is None:
                return
            st["last_analysis_time"] = time.time()
            st["last_analysis_step"] = summ.get("frame_step_last") or summ.get("step_last")
            st["analysis"] = {k: v for k, v in summ.items() if k != "caveats"}
            snaps = P.list_snaps(rd)
            dsteps = sorted(set(st.get("division_steps", [])) | set(summ.get("division_steps", [])))
            st["division_steps"] = dsteps
            prot = set(st.get("protected", [])) | protected_steps(snaps, dsteps, self.cfg["div_window"])
            st["protected"] = sorted(prot)
            self.save()
            self.append_history(summ)
            self.log(f"analyse tot stap {P.fmt_int(st['last_analysis_step'])}: {summ.get('cells_last', '?')} cellen, "
                     f"{summ['divisions']} delingen, checklist {summ['n_ja']} ja / {summ['n_deels']} deels "
                     f"({P.fmt_dur(time.time() - t0)})")
            if self.cfg["render"]:
                self.render(summ)
            self.thin()
            self.write_status()
        except Exception as e:  # never let maintenance kill the run
            self.log(f"onderhoud mislukt: {e!r}")

    def append_history(self, s):
        p = os.path.join(self.rundir, "pc_history.csv")
        new = not os.path.exists(p)
        with open(p, "a") as f:
            if new:
                f.write("tijd,stap,cellen,cellen_met_katalysator,delingen,bevestigd,ja,deels\n")
            f.write(f"{P.stamp()},{self.st.get('last_analysis_step')},{s.get('cells_last', '')},{s.get('cat_cells_last', '')},"
                    f"{s['divisions']},{s['divisions_confirmed']},{s['n_ja']},{s['n_deels']}\n")

    def render(self, summ):
        st = self.st
        name = os.path.basename(self.rundir)
        out_dir = os.path.join(st["beelden_dir"], name)
        os.makedirs(out_dir, exist_ok=True)
        step = st["last_analysis_step"]
        imgs = st.setdefault("images", {})
        w = str(self.cfg["width"])
        tag = f"{int(step):010d}"
        r = os.path.join(P.TOOLS, "render.py")
        f = os.path.join(out_dir, f"micro_{tag}.png")
        if self.run_tool([r, self.rundir, "--kind", "micro", "--step", str(step), "--out", f, "--width", w],
                         "micro-beeld", timeout=3600):
            imgs.setdefault("micro", []).append(f)
        it = P.interesting_track(self.rundir)
        if it is not None:
            tid, tstep = it
            f = os.path.join(out_dir, f"goodsell_{int(tstep):010d}_spoor{tid}.png")
            if self.run_tool([r, self.rundir, "--kind", "goodsell", "--cell", str(tid), "--step", str(tstep), "--out", f,
                              "--width", w], "goodsell-beeld", timeout=3600):
                imgs.setdefault("goodsell", []).append(f)
        if summ.get("divisions", 0) > 0:
            sig = f"{summ['divisions']}:{summ['divisions_confirmed']}:{summ.get('division_steps')}"
            if sig != st.get("timelapse_sig"):
                f = os.path.join(out_dir, f"timelapse_{tag}.png")
                if self.run_tool([r, self.rundir, "--kind", "timelapse", "--out", f, "--width", str(max(2400, int(w)))],
                                 "time-lapse", timeout=3600):
                    imgs.setdefault("timelapse", []).append(f)
                    st["timelapse_sig"] = sig
        keep = max(1, int(self.cfg["images_keep"]))
        for kind, lst in imgs.items():
            lst[:] = [x for x in dict.fromkeys(lst) if os.path.exists(x)]
            while len(lst) > keep:
                old = lst.pop(0)
                try:
                    os.unlink(old)
                except OSError:
                    pass
        self.save()

    def thin(self):
        st = self.st
        rd = self.rundir
        snaps = P.list_snaps(rd)
        se = snap_interval(rd, snaps)
        ck, ckm = P.ckpt_info(rd)
        if ck is None and ckm is not None:   # unknown checkpoint format: protect everything newer by mtime
            newer = [s for s, p in snaps if os.path.getmtime(p) >= ckm]
            ck = newer[0] if newer else None
        stride = int(st.get("max_stride_eff", self.cfg["max_stride"]))
        budget = float(self.cfg["max_snap_gb"]) * 1024 ** 3
        removed = 0
        for _ in range(12):
            plan = thinning_plan(snaps, se, st.get("last_analysis_step"), ck, st.get("protected", []),
                                 int(self.cfg["keep_recent"]), stride)
            for s, p in plan:
                try:
                    os.unlink(p)
                    removed += 1
                except OSError:
                    pass
                for c in (f"cells_{s:010d}.json", f"grid_{s:010d}.npz"):
                    try:
                        os.unlink(os.path.join(rd, "analysis_cache", c))
                    except OSError:
                        pass
            snaps = P.list_snaps(rd)
            used = sum(os.path.getsize(p) for _, p in snaps if os.path.exists(p))
            if budget <= 0 or used <= budget or stride >= 1 << 20:
                break
            stride *= 2
            self.log(f"snapshots gebruiken {P.fmt_bytes(used)} > budget {P.fmt_bytes(budget)}: oude snapshots dunner (stap x{stride})")
        st["max_stride_eff"] = stride
        st["thinned_total"] = st.get("thinned_total", 0) + removed
        if removed:
            self.log(f"uitdunnen: {removed} oude snapshots verwijderd ({len(snaps)} over)")
        self.save()

    # -- STATUS.md
    def write_status(self):
        try:
            P.write_text_atomic(os.path.join(self.rundir, "STATUS.md"), status_markdown(self.rundir, self.st, self.speed()))
        except Exception as e:
            self.log(f"STATUS.md schrijven mislukt: {e!r}")


def status_markdown(rundir, st, speed=None):
    name = os.path.basename(rundir)
    tgt = int(st["steps"])
    cur = P.current_step(rundir)
    holder = P.lock_holder(rundir)
    status = st.get("status", "?")
    if status == "fout":
        status = "FOUT: supervisor gestopt na herhaalde crashes (zie pc_supervisor.log, pc_engine.out, log.txt)"
    elif status == "klaar":
        status = f"klaar ({st.get('finished', '')})"
    elif status == "gestopt":
        status = "gestopt op verzoek (hervat met hetzelfde commando)"
    elif holder:
        status = f"loopt (supervisor pid {holder})"
    else:
        status = "onderbroken (supervisor draait niet; hervat met hetzelfde commando)"
    eng = st.get("engine", "?").upper() + "-engine"
    if st.get("engine") == "gpu":
        g = P.gpu_info()
        if g:
            eng += f" ({g[0]['name']}, {g[0]['util']} % bezet, {g[0]['mem_used']}/{g[0]['mem_total']} MiB)"
    dt = None
    try:
        dt = float(P.read_ini(os.path.join(rundir, "params.ini")).get("dt", 0)) or None
    except (OSError, ValueError):
        pass
    sl = P.stats_last(rundir)
    lines = [f"# Lange run: {name}", "", f"_bijgewerkt {P.stamp()}_", "", "| | |", "|---|---|",
             f"| status | {status} |", f"| engine | {eng} |",
             f"| stappen | {P.fmt_int(cur)} / {P.fmt_int(tgt)} ({P.fmt_float(100.0 * cur / max(1, tgt), 1)} %) |"]
    if sl and "time" in sl:
        lines.append(f"| simulatietijd | {P.fmt_float(sl['time'], 0)} τ |")
    if speed:
        tau = f" · {P.fmt_int(speed * dt * 3600)} τ/uur" if dt else ""
        lines.append(f"| snelheid | {P.fmt_int(speed)} stappen/s{tau} |")
        if cur < tgt and holder:
            lines.append(f"| klaar over | ~{P.fmt_dur((tgt - cur) / speed)} |")
    lc = st.get("last_crash")
    lines.append(f"| herstarts | {st.get('chunks', 0)} chunks, {st.get('crashes', 0)} crashes"
                 + (f" (laatste {lc['time']}, code {lc['rc']}, stap {P.fmt_int(lc['step'])})" if lc else "") + " |")
    snaps = P.list_snaps(rundir)
    ssz = sum(os.path.getsize(p) for _, p in snaps if os.path.exists(p))
    lines.append(f"| schijf | {len(snaps)} snapshots ({P.fmt_bytes(ssz)}), {len(P.list_ckpt_copies(rundir))} checkpoint-kopieën, "
                 f"{st.get('thinned_total', 0)} snapshots uitgedund; vrij {P.fmt_bytes(P.disk_free(rundir) or 0)} |")
    a = st.get("analysis")
    lines.append("")
    if a:
        ago = P.fmt_dur(time.time() - st.get("last_analysis_time", time.time()))
        lines += [f"## Cellen (analyse t/m stap {P.fmt_int(st.get('last_analysis_step'))}, {ago} geleden)", "",
                  f"- gesloten cellen nu: {a.get('cells_last', '?')} (max {a.get('cells_max', '?')}); "
                  f"met katalysatoren: {a.get('cat_cells_last', '?')} (max {a.get('cat_cells_max', '?')})",
                  f"- sporen: {a.get('n_tracks', '?')}; delingen: {a.get('divisions', 0)} ({a.get('divisions_confirmed', 0)} bevestigd)"
                  + (f" bij stap {', '.join(P.fmt_int(s) for s in a.get('division_steps', [])[:8])}" if a.get("division_steps") else "")
                  + f"; fusies: {a.get('fusions', 0)}; max generatie: {a.get('max_generation', 0)}", "",
                  "## Levens-checklist", "", "| # | criterium | status | samenvatting |", "|---|---|---|---|"]
        for c in a.get("checklist", []):
            lines.append(f"| {c['id']} | {c['naam']} | **{c['status']}** | {c['samenvatting']} |")
    else:
        lines += ["## Cellen", "", f"nog geen analyse (eerste analyse na ~{P.fmt_float(st['settings']['analyse_uur'], 1)} uur)"]
    imgs = st.get("images", {})
    if any(imgs.values()):
        lines += ["", "## Laatste beelden", ""]
        for kind in ("micro", "goodsell", "timelapse"):
            if imgs.get(kind):
                lines.append(f"- {kind}: `{os.path.relpath(imgs[kind][-1], P.CEL)}`")
    lines += ["", "Hervatten (na crash/reboot): `python3 pc/longrun.py " + name + " --achtergrond`  ·  "
              "stoppen: `python3 pc/longrun.py " + name + " --stop`", ""]
    return "\n".join(lines)


# ----------------------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("naam", help="naam van de run (map runs/NAAM)")
    ap.add_argument("--ini", help="basis-parameterbestand (alleen bij een nieuwe run)")
    ap.add_argument("--set", nargs="*", default=[], metavar="k=v", help="parameters die de ini overschrijven (nieuwe run)")
    ap.add_argument("--steps", type=float, default=None, help="doel-stap (absoluut); mag bij hervatten omhoog")
    ap.add_argument("--engine", default=None, help="auto (GPU als die werkt, anders CPU) | cpu | gpu | pad naar binary")
    ap.add_argument("--forceer-engine", action="store_true", help="engine van een bestaande run wisselen (checkpoint moet passen!)")
    ap.add_argument("--van-ckpt", default=None, help="nieuwe run beginnen vanaf het checkpoint van een eerdere soep-run (SPEC §4)")
    ap.add_argument("--adopteer", action="store_true",
                    help="een bestaande run-map (met params.ini, gemaakt zonder longrun.py) onder supervisie nemen")
    ap.add_argument("--threads", type=int, default=None, help="OpenMP-threads (standaard: GPU 2, CPU alle kernen)")
    ap.add_argument("--chunk-min", type=float, default=None, help="minuten per engine-chunk (standaard 60)")
    ap.add_argument("--analyse-uur", type=float, default=None, help="elke X uur analyse + beelden (standaard 2; 0 = alleen aan het eind)")
    ap.add_argument("--analyse-jobs", type=int, default=None, help="processen voor analyze.py (standaard 8)")
    ap.add_argument("--keep-recent", type=int, default=None, help="nieuwste N geanalyseerde snapshots altijd houden (200)")
    ap.add_argument("--max-stride", type=int, default=None, help="oudste snapshots: 1 op de N houden (64)")
    ap.add_argument("--max-snap-gb", type=float, default=None, help="schijfbudget snapshots in GB (100)")
    ap.add_argument("--keep-ckpt", type=int, default=None, help="aantal checkpoint-kopieën (3)")
    ap.add_argument("--div-window", type=int, default=None, help="snapshots rond een deling altijd houden (10 ervoor en erna)")
    ap.add_argument("--images-keep", type=int, default=None, help="beelden per soort bewaren in beelden/NAAM (4)")
    ap.add_argument("--width", type=int, default=None, help="beeldbreedte in pixels (2000)")
    ap.add_argument("--geen-beelden", action="store_true", help="geen beelden maken (alleen analyse)")
    ap.add_argument("--runs-dir", default=None)
    ap.add_argument("--beelden-dir", default=None)
    ap.add_argument("--achtergrond", action="store_true", help="los van de terminal draaien (nohup/setsid)")
    ap.add_argument("--stop", action="store_true", help="draaiende supervisor netjes stoppen")
    ap.add_argument("--analyseer-nu", action="store_true", help="draaiende supervisor meteen laten analyseren")
    ap.add_argument("--poll", type=float, default=None, help=argparse.SUPPRESS)
    ap.add_argument("--_bg", action="store_true", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if a._bg:
        P.LOG_STDOUT = False

    name = a.naam.strip("/").split("/")[-1]
    rundir = os.path.join(P.runs_dir(a.runs_dir), name)
    stp = os.path.join(rundir, STATE)

    if a.stop or a.analyseer_nu:
        pid = P.lock_holder(rundir) if os.path.isdir(rundir) else None
        if not pid or pid == "?":
            print(f"{name}: geen draaiende supervisor")
            if a.stop:
                strays = P.engine_pids_for(rundir)
                if strays:
                    print(f"losse engine-processen {strays} netjes stoppen")
                    P.stop_pids(strays)
            return 0
        os.kill(int(pid), signal.SIGUSR1 if a.analyseer_nu else signal.SIGTERM)
        if a.analyseer_nu:
            print(f"{name}: analyse aangevraagd bij pid {pid}")
            return 0
        print(f"{name}: stopsignaal naar pid {pid}; wachten tot de engine een checkpoint heeft geschreven ...")
        t0 = time.time()
        while P.pid_alive(int(pid)) and time.time() - t0 < 600:
            time.sleep(1)
        print(f"{name}: {'gestopt' if not P.pid_alive(int(pid)) else 'nog bezig (kijk later met pc/status.py)'}")
        return 0

    st = P.read_json(stp)
    if st is None and a.adopteer:
        prm = os.path.join(rundir, "params.ini")
        if not os.path.exists(prm):
            raise SystemExit(f"--adopteer: {prm} bestaat niet")
        if a.ini or a.set or a.van_ckpt:
            raise SystemExit("--adopteer neemt de parameters uit params.ini van de run; geen --ini/--set/--van-ckpt")
        base = P.read_ini(prm)
        with open(prm) as f, open(os.path.join(rundir, "pc_base.ini"), "w") as g:
            g.write("# overgenomen uit params.ini door longrun.py --adopteer (restart/walltime/threads/ckpt_keep regelt de supervisor)\n")
            for line in f:
                k = line.split("#", 1)[0].split("=", 1)[0].strip()
                if k not in P.RESERVED_KEYS:
                    g.write(line)
        label, binary = P.resolve_engine(a.engine or "cpu", "longrun")
        steps = int(a.steps) if a.steps is not None else int(float(base.get("steps", 0)))
        st = dict(kind="longrun", version=VERSION, name=name, created=P.stamp(), ini_source=f"(geadopteerd) {name}/params.ini",
                  overrides={}, steps=steps, engine=label, engine_path=binary, engine_sha1=P.file_sha1(binary),
                  from_ckpt=None, beelden_dir=P.beelden_dir(a.beelden_dir), settings=dict(SETTINGS_DEFAULTS),
                  status="nieuw", chunks=0, crashes=0, adopted=True)
        st["settings"]["threads"] = 2 if label == "gpu" else min(32, max(1, P.cpu_count() - 2))
        if not P.restart_candidates(rundir):
            raise SystemExit(f"--adopteer: geen checkpoint (ckpt.bin) in {rundir}; zo'n run kan niet verder")
    elif st is None:
        if not a.ini:
            raise SystemExit(f"run {name} bestaat nog niet: geef --ini (en eventueel --set) voor een nieuwe run")
        ini = a.ini if os.path.isabs(a.ini) else (a.ini if os.path.exists(a.ini) else os.path.join(P.CEL, a.ini))
        if not os.path.exists(ini):
            raise SystemExit(f"ini niet gevonden: {a.ini}")
        base = P.read_ini(ini)
        ov = P.parse_kv_list(a.set)
        bad = sorted(set(ov) & P.RESERVED_KEYS) + sorted(set(base) & {"restart"} if base.get("restart") else [])
        if bad:
            raise SystemExit(f"deze sleutels regelt longrun.py zelf: {', '.join(bad)} (gebruik --van-ckpt / --threads)")
        if a.steps is not None:
            ov["steps"] = str(int(a.steps))
        steps = int(float(ov.get("steps", base.get("steps", 10000))))
        ov.pop("steps", None)
        label, binary = P.resolve_engine(a.engine or "auto", "longrun")
        miss = P.unsupported_keys(binary, set(base) | set(ov))
        if miss:
            raise SystemExit(f"de {label}-engine ({binary}) kent deze parameters niet: {', '.join(miss)}.\n"
                             f"Kies een engine die ze wel kent met --engine PAD (bijv. een build van runs/memB_src/oercel.c).")
        os.makedirs(rundir, exist_ok=True)
        if P.list_snaps(rundir) and not os.path.exists(stp):
            raise SystemExit(f"{rundir} bestaat al met snapshots maar is geen longrun-map; kies een andere naam")
        shutil.copyfile(ini, os.path.join(rundir, "pc_base.ini"))
        frm = None
        if a.van_ckpt:
            frm = os.path.abspath(a.van_ckpt)
            if not os.path.exists(frm):
                raise SystemExit(f"checkpoint niet gevonden: {a.van_ckpt}")
        st = dict(kind="longrun", version=VERSION, name=name, created=P.stamp(), ini_source=os.path.relpath(ini, P.CEL),
                  overrides=ov, steps=steps, engine=label, engine_path=binary, engine_sha1=P.file_sha1(binary),
                  from_ckpt=frm, beelden_dir=P.beelden_dir(a.beelden_dir), settings=dict(SETTINGS_DEFAULTS),
                  status="nieuw", chunks=0, crashes=0)
        st["settings"]["threads"] = 2 if label == "gpu" else min(32, max(1, P.cpu_count() - 2))
    else:
        if a.ini or a.set or a.van_ckpt:
            raise SystemExit(f"run {name} bestaat al: --ini/--set/--van-ckpt kunnen niet meer veranderen "
                             f"(kies een nieuwe naam voor een ander experiment)")
        if a.steps is not None:
            if int(a.steps) < int(st["steps"]):
                raise SystemExit("--steps mag bij hervatten alleen omhoog")
            st["steps"] = int(a.steps)
        if a.engine:
            label, binary = P.resolve_engine(a.engine, "longrun")
            if binary != st["engine_path"] and not a.forceer_engine:
                raise SystemExit(f"run {name} draait op {st['engine']} ({st['engine_path']}); wisselen kan alleen met "
                                 f"--forceer-engine (het checkpoint-formaat moet passen)")
            st["engine"], st["engine_path"] = label, binary
        if st["engine"] == "cpu":
            P.ensure_built("cpu")
        if not os.path.exists(st["engine_path"]):
            raise SystemExit(f"engine ontbreekt: {st['engine_path']} (draai pc/setup_wsl.sh)")
        sha = P.file_sha1(st["engine_path"])
        if sha != st.get("engine_sha1"):
            st.setdefault("engine_changes", []).append(dict(time=P.stamp(), old=st.get("engine_sha1"), new=sha))
            st["engine_sha1"] = sha
            print(f"LET OP: de engine-binary is veranderd sinds de vorige start (opnieuw gebouwd?). De run gaat door; "
                  f"dit staat genoteerd in {STATE}.")
        if a.beelden_dir:
            st["beelden_dir"] = P.beelden_dir(a.beelden_dir)
    s = st["settings"]
    for k, v in (("threads", a.threads), ("chunk_min", a.chunk_min), ("analyse_uur", a.analyse_uur),
                 ("analyse_jobs", a.analyse_jobs), ("keep_recent", a.keep_recent), ("max_stride", a.max_stride),
                 ("max_snap_gb", a.max_snap_gb), ("keep_ckpt", a.keep_ckpt), ("div_window", a.div_window),
                 ("images_keep", a.images_keep), ("width", a.width), ("poll_s", a.poll)):
        if v is not None:
            s[k] = v
    if a.geen_beelden:
        s["render"] = False
    for k, v in SETTINGS_DEFAULTS.items():
        s.setdefault(k, v)
    if a.max_stride is not None:
        st.pop("max_stride_eff", None)

    holder = P.lock_holder(rundir) if os.path.isdir(rundir) else None
    if holder:
        print(f"{name}: supervisor draait al (pid {holder}); status: runs/{name}/STATUS.md")
        return 0
    os.makedirs(rundir, exist_ok=True)
    P.write_json_atomic(stp, st)

    if a.achtergrond:
        argv = [name]
        if a.runs_dir:
            argv += ["--runs-dir", a.runs_dir]
        pid = P.detach(os.path.abspath(__file__), argv, os.path.join(rundir, "pc_supervisor.out"))
        time.sleep(1.5)
        print(f"{name}: supervisor gestart op de achtergrond (pid {pid}); log: {os.path.join(rundir, SUPLOG)}")
        print(f"  status: python3 pc/status.py   of   cat {os.path.join(rundir, 'STATUS.md')}")
        return 0

    try:
        lock = P.DirLock(rundir).acquire()
    except P.AlreadyRunning as e:
        print(f"{name}: supervisor draait al (pid {e.pid})")
        return 0
    logf = open(os.path.join(rundir, SUPLOG), "a")
    sup = Supervisor(rundir, st, logf)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGUSR1):
        signal.signal(sig, sup.on_signal)
    sup.log(f"supervisor start: {name}, {st['engine']}-engine {st['engine_path']}, doel stap {P.fmt_int(st['steps'])}, "
            f"threads {s['threads']}, chunk {s['chunk_min']} min, analyse elke {s['analyse_uur']} u")
    try:
        rc = sup.run()
    finally:
        lock.release()
        logf.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
