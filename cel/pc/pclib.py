#!/usr/bin/env python3
"""Shared helpers for the Oercel workstation scripts in cel/pc/ (standard library only).

sweep.py, longrun.py and status.py import this module.  Nothing here touches the physics: it only
starts the engine binaries (engine/oercel or engine_gpu/oercel_gpu) with key=value overrides,
restarts them from their own checkpoints, and reads the SPEC section 5 output files.
"""
import ctypes
import datetime
import errno
import fcntl
import glob
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import time

PC = os.path.dirname(os.path.abspath(__file__))
CEL = os.path.dirname(PC)
ENGINE_DIR = os.path.join(CEL, "engine")
ENGINE_CPU = os.path.join(ENGINE_DIR, "oercel")
ENGINE_GPU_DIR = os.path.join(CEL, "engine_gpu")
ENGINE_GPU = os.environ.get("OERCEL_ENGINE_GPU") or os.path.join(ENGINE_GPU_DIR, "oercel_gpu")  # env: tests only
TOOLS = os.path.join(CEL, "tools")
VENV_PY = os.path.join(PC, ".venv", "bin", "python")


REPO = os.path.dirname(CEL)


def shown_cmd(script, args="", for_file=False):
    """A pc/ command line to show to a person or to Claude.  In files (STATUS.md, logs) relative to the
    repository root, where the README's commands are typed (python3 cel/pc/...); on the terminal relative
    to the current directory when that is inside the repository, else absolute."""
    p = os.path.join(PC, script)
    if for_file:
        rel = os.path.relpath(p, REPO)
    else:
        rel = os.path.relpath(p, os.getcwd())
        if rel.startswith(".."):
            rel = p
    return f"python3 {rel}" + (f" {args}" if args else "")


def shown_path(p):
    """p relative to the current directory when that is inside the repository, else absolute."""
    rel = os.path.relpath(p, os.getcwd())
    return p if rel.startswith("..") else rel


def runs_arg(d):
    """' --runs-dir /abs/path' when directory d is not directly in the default runs/ directory."""
    parent = os.path.dirname(os.path.abspath(d))
    return "" if parent == runs_dir() else f" --runs-dir {parent}"


def runs_dir(arg=None):
    return os.path.abspath(arg or os.environ.get("OERCEL_RUNS") or os.path.join(CEL, "runs"))


def beelden_dir(arg=None):
    return os.path.abspath(arg or os.environ.get("OERCEL_BEELDEN") or os.path.join(CEL, "beelden"))


def tools_python():
    """Python used for tools/*.py: the venv made by setup_wsl.sh if it exists, else this one."""
    if os.path.isfile(VENV_PY) and os.access(VENV_PY, os.X_OK):
        return VENV_PY
    return sys.executable


# ----------------------------------------------------------------------------- small utilities
def now():
    return time.time()


def stamp(t=None):
    return datetime.datetime.fromtimestamp(t if t is not None else time.time()).strftime("%Y-%m-%d %H:%M:%S")


LOG_STDOUT = True   # False in a detached supervisor: its stdout is a crash-trace file, the log has its own file


def log(msg, fh=None):
    line = f"[{stamp()}] {msg}"
    if LOG_STDOUT or fh is None:
        print(line, flush=True)
    if fh is not None:
        fh.write(line + "\n")
        fh.flush()


def fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def write_text_atomic(path, text):
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fsync_dir(os.path.dirname(os.path.abspath(path)))


def write_json_atomic(path, obj):
    for i in range(20):  # another thread may be changing obj: retry the serialisation
        try:
            text = json.dumps(obj, indent=1, ensure_ascii=False, sort_keys=False) + "\n"
            break
        except RuntimeError:
            time.sleep(0.01)
    else:
        text = json.dumps(json.loads(json.dumps(obj, default=str)), indent=1, ensure_ascii=False)
    write_text_atomic(path, text)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def fmt_int(v):
    """Dutch thousands separator: 1234567 -> 1.234.567"""
    try:
        return f"{int(v):,}".replace(",", ".")
    except (TypeError, ValueError):
        return "?"


def fmt_float(v, nd=1):
    try:
        s = f"{float(v):,.{nd}f}"
    except (TypeError, ValueError):
        return "?"
    return s.replace(",", "_").replace(".", ",").replace("_", ".")


def fmt_dur(sec):
    if sec is None or sec != sec or sec < 0:
        return "?"
    sec = int(sec)
    d, r = divmod(sec, 86400)
    h, r = divmod(r, 3600)
    m, _ = divmod(r, 60)
    if d:
        return f"{d} d {h} u"
    if h:
        return f"{h} u {m:02d} min"
    return f"{m} min" if m else f"{sec} s"


def fmt_bytes(n):
    n = float(n)
    for u in ("B", "kB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{fmt_float(n, 0 if u in ('B', 'kB') else 1)} {u}"
        n /= 1024.0


def dir_size(path, pattern="*"):
    """Bytes on disk of the files matching pattern (hard links counted once)."""
    tot, seen = 0, set()
    for p in glob.glob(os.path.join(path, pattern)):
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if os.path.isfile(p) and (st.st_dev, st.st_ino) not in seen:
            seen.add((st.st_dev, st.st_ino))
            tot += st.st_blocks * 512
    return tot


def tree_size(path):
    tot = 0
    for root, _, files in os.walk(path):
        for fn in files:
            try:
                tot += os.lstat(os.path.join(root, fn)).st_blocks * 512
            except OSError:
                pass
    return tot


# ----------------------------------------------------------------------------- ini handling
def read_ini(path):
    """key = value file -> dict (insertion ordered).  '#' starts a comment (as in the engine)."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line or (line.startswith("[") and line.endswith("]")):
                continue
            if "=" not in line:
                raise ValueError(f"{path}:{ln}: verwacht 'sleutel = waarde'")
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def parse_kv_list(items):
    """['a=1', 'b = 2'] -> {'a': '1', 'b': '2'}"""
    out = {}
    for it in items or []:
        if "=" not in it:
            raise ValueError(f"verwacht sleutel=waarde, kreeg '{it}'")
        k, v = it.split("=", 1)
        k, v = k.strip(), v.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            raise ValueError(f"ongeldige parameternaam '{k}'")
        out[k] = v
    return out


# Dutch labels for the job states of a sweep (pc_sweep.json keeps the short keys)
JOB_LABEL = {"wacht": "wachtend", "loopt": "lopend", "klaar": "klaar (analyse volgt)", "analyse": "in analyse",
             "geanalyseerd": "geanalyseerd", "fout": "MISLUKT", "analyse_fout": "analyse MISLUKT"}

# keys the supervisors set themselves; they must not come from job files or overrides
RESERVED_KEYS = {"restart", "walltime", "threads", "ckpt_keep"}


# ----------------------------------------------------------------------------- engines
_KEYS_CACHE = {}


def engine_keys(binary):
    """Set of parameter names an engine binary accepts (parsed from `binary --params`), or None."""
    key = (binary, os.path.getmtime(binary) if os.path.exists(binary) else 0)
    if key in _KEYS_CACHE:
        return _KEYS_CACHE[key]
    keys = None
    try:
        r = subprocess.run([binary, "--params"], capture_output=True, text=True, timeout=60)
        found = set(re.findall(r"^\|\s*`([A-Za-z0-9_]+)`\s*\|", r.stdout, re.M))
        if found:
            keys = found
    except (OSError, subprocess.SubprocessError):
        keys = None
    _KEYS_CACHE[key] = keys
    return keys


def unsupported_keys(binary, keys):
    """Keys the engine does not list in --params (repulsion keys a_X_Y are checked by the engine)."""
    known = engine_keys(binary)
    if known is None:
        return []
    return sorted(k for k in keys if not k.startswith("a_") and k not in known)


def nvidia_smi():
    p = shutil.which("nvidia-smi")
    if p:
        return p
    if os.path.exists("/usr/lib/wsl/lib/nvidia-smi"):
        return "/usr/lib/wsl/lib/nvidia-smi"
    return None


def gpu_info():
    """List of GPUs as dicts (name, mem_total, mem_used, util, temp), or None without a working GPU."""
    smi = nvidia_smi()
    if not smi:
        return None
    try:
        r = subprocess.run([smi, "--query-gpu=name,memory.total,memory.used,utilization.gpu,temperature.gpu",
                            "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    out = []
    for line in r.stdout.strip().splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) >= 5:
            out.append(dict(name=f[0], mem_total=f[1], mem_used=f[2], util=f[3], temp=f[4]))
    return out or None


def gpu_processes():
    smi = nvidia_smi()
    if not smi:
        return []
    try:
        r = subprocess.run([smi, "--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=20)
        return [l.strip() for l in r.stdout.strip().splitlines() if l.strip()]
    except (OSError, subprocess.SubprocessError):
        return []


def _newer(src_glob, binary):
    try:
        bt = os.path.getmtime(binary)
    except OSError:
        return True
    return any(os.path.getmtime(p) > bt for p in glob.glob(src_glob))


def ensure_built(kind, logf=None):
    """Build engine/oercel (or engine_gpu/oercel_gpu) when it is missing or older than its source."""
    if kind == "cpu":
        d, b, src = ENGINE_DIR, ENGINE_CPU, "*.c"
        target = ["oercel"]
    elif kind == "gpu":
        d, b, src = ENGINE_GPU_DIR, ENGINE_GPU, "*.c*"
        target = []
    else:
        return os.path.exists(kind)
    if os.environ.get("OERCEL_NO_BUILD") == "1":   # tests on a shared machine: never touch engine/
        return os.path.exists(b)
    if not os.path.exists(os.path.join(d, "Makefile")):
        return os.path.exists(b)
    if os.path.exists(b) and not _newer(os.path.join(d, src), b) and not _newer(os.path.join(d, "*.h"), b):
        return True
    log(f"engine bouwen: make -C {os.path.relpath(d, CEL)} {' '.join(target)}", logf)
    env = dict(os.environ)
    for cb in (os.path.join(ENGINE_GPU_DIR, ".cuda", "bin"), "/usr/local/cuda/bin"):  # local (no-root) nvcc, system toolkit
        if os.path.isdir(cb) and cb not in env.get("PATH", "").split(":"):
            env["PATH"] = cb + ":" + env.get("PATH", "")
    r = subprocess.run(["make", "-C", d] + target, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        log(f"FOUT bij bouwen van {d}:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}", logf)
        return os.path.exists(b)
    return os.path.exists(b)


BUILD_DIR = os.path.join(PC, "_build")                       # git-ignored
# written by setup_wsl.sh / cache of gpu_smoke_test(); the env variables are for tests only
GPU_SELFTEST_FILE = os.environ.get("OERCEL_GPU_SELFTEST_FILE") or os.path.join(BUILD_DIR, "gpu_selftest.json")
GPU_SMOKE_FILE = os.environ.get("OERCEL_GPU_SMOKE_FILE") or os.path.join(BUILD_DIR, "gpu_smoke.json")


def gpu_smoke_test(binary, timeout=180):
    """(ok, message): does `binary` really run on this machine?  A 20-step soup (L=32) in a
    temporary directory; the result is cached per binary checksum in pc/_build/gpu_smoke.json, so
    a rebuilt binary is tested again.  Nothing here touches a real run."""
    import tempfile
    sha = file_sha1(binary)
    cache = read_json(GPU_SMOKE_FILE, {}) or {}
    c = cache.get(sha) if sha else None
    if c is not None and c.get("ok"):
        return True, c.get("msg", "")
    tmp = tempfile.mkdtemp(prefix="oercel_gpu_smoke_")
    try:
        r = subprocess.run([binary, "/dev/null", os.path.join(tmp, "r"), "L=32", "steps=20", "snap_every=0",
                            "log_every=0", "threads=1"], capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        lg = tail_text(os.path.join(tmp, "r", "log.txt"), 4096)
        ok = r.returncode == 0 and "done at step 20" in lg
        err = [l for l in (r.stderr + r.stdout).splitlines() if l.strip()]
        msg = "proefrun van 20 stappen gelukt" if ok else (f"proefrun mislukt (code {r.returncode}): "
                                                           + (err[-1] if err else "geen melding"))[:300]
    except subprocess.TimeoutExpired:
        ok, msg = False, f"proefrun van 20 stappen duurde langer dan {timeout} s"
    except OSError as e:
        ok, msg = False, f"proefrun kon niet starten: {e}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if sha:
        try:
            os.makedirs(os.path.dirname(GPU_SMOKE_FILE), exist_ok=True)
            cache[sha] = dict(ok=ok, msg=msg, time=stamp(), binary=binary)
            write_json_atomic(GPU_SMOKE_FILE, cache)
        except OSError:
            pass
    return ok, msg


def gpu_engine_check(binary=None):
    """(ok, reason) for using the GPU engine: the binary exists, nvidia-smi sees a GPU, the setup's
    GPU self-test did not FAIL for exactly this binary, and a 20-step proefrun works."""
    b = binary or ENGINE_GPU
    if not (os.path.isfile(b) and os.access(b, os.X_OK)):
        return False, f"{os.path.relpath(b, CEL)} ontbreekt of kon niet gebouwd worden"
    if gpu_info() is None:
        return False, "nvidia-smi ziet geen GPU"
    st = read_json(GPU_SELFTEST_FILE)
    if st and st.get("sha1") == file_sha1(b) and st.get("ok") is False:
        return False, (f"de GPU-zelftest van setup_wsl.sh faalde voor deze build ({st.get('time', '?')}; "
                       f"log: {st.get('log', 'runs/_setup/selftest_gpu.log')})")
    ok, msg = gpu_smoke_test(b)
    return (True, msg) if ok else (False, f"de GPU-engine draait niet: {msg}")


def gpu_engine_usable():
    return gpu_engine_check()[0]


def resolve_engine(choice, purpose, logf=None):
    """choice: auto | cpu | gpu | <path to a binary with the same CLI>.
    Returns (label, absolute binary path).  auto = gpu for long runs when a GPU engine and a working
    GPU exist (and the engine passes gpu_engine_check), cpu otherwise; sweeps default to cpu."""
    choice = (choice or "auto").strip()
    if choice == "auto":
        if purpose == "longrun":
            g = gpu_info()
            if os.path.exists(os.path.join(ENGINE_GPU_DIR, "Makefile")) and g is not None:
                ensure_built("gpu", logf)
            ok, why = gpu_engine_check()
            if ok:
                return "gpu", ENGINE_GPU
            log(f"LET OP: GPU-engine niet bruikbaar ({why}); deze run gebruikt de CPU-engine", logf)
        choice = "cpu"
    if choice == "cpu":
        ensure_built("cpu", logf)
        if not os.path.exists(ENGINE_CPU):
            raise SystemExit(f"CPU-engine ontbreekt: {ENGINE_CPU} (draai pc/setup_wsl.sh of make -C engine)")
        return "cpu", ENGINE_CPU
    if choice == "gpu":
        ensure_built("gpu", logf)
        if not os.path.exists(ENGINE_GPU):
            raise SystemExit(f"GPU-engine ontbreekt: {ENGINE_GPU} (draai pc/setup_wsl.sh)")
        ok, why = gpu_engine_check()
        if not ok:
            raise SystemExit(f"GPU-engine niet bruikbaar: {why.rstrip('.')}.\nGebruik --engine cpu (of auto: kiest dan zelf de CPU).")
        return "gpu", ENGINE_GPU
    p = os.path.abspath(choice)
    if not (os.path.isfile(p) and os.access(p, os.X_OK)):
        raise SystemExit(f"engine '{choice}' bestaat niet of is niet uitvoerbaar")
    return "pad", p


def file_sha1(path):
    import hashlib
    h = hashlib.sha1()
    try:
        with open(path, "rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
    except OSError:
        return None
    return h.hexdigest()[:16]


# ----------------------------------------------------------------------------- run directory files
SNAP_RE = re.compile(r"^snap_(\d+)\.bin$")
CKPT_RE = re.compile(r"^ckpt_(\d+)\.bin$")
SNAP_HEADER = 4 + 4 + 4 + 4 + 8 + 8 + 8


def list_snaps(rundir):
    out = []
    try:
        names = os.listdir(rundir)
    except OSError:
        return out
    for n in names:
        m = SNAP_RE.match(n)
        if m:
            out.append((int(m.group(1)), os.path.join(rundir, n)))
    out.sort()
    return out


def snaps_bytes(snaps):
    """Total size of a list of (step, path) snapshots; files removed meanwhile (thinning) count 0."""
    tot = 0
    for _, p in snaps:
        try:
            tot += os.path.getsize(p)
        except OSError:
            pass
    return tot


def snap_complete(path):
    try:
        with open(path, "rb") as f:
            b = f.read(SNAP_HEADER)
        if len(b) < SNAP_HEADER or b[:4] != b"OCEL":
            return False
        _, n, nb = struct.unpack_from("<iii", b, 4)
        return os.path.getsize(path) == SNAP_HEADER + 9 * n + 8 * nb
    except OSError:
        return False


def snap_header(path):
    with open(path, "rb") as f:
        b = f.read(SNAP_HEADER)
    _, n, nb = struct.unpack_from("<iii", b, 4)
    step, t, L = struct.unpack_from("<qdd", b, 16)
    return dict(N=n, nbonds=nb, step=step, time=t, L=L)


def list_ckpt_copies(rundir):
    out = []
    try:
        names = os.listdir(rundir)
    except OSError:
        return out
    for n in names:
        m = CKPT_RE.match(n)
        if m:
            out.append((int(m.group(1)), os.path.join(rundir, n)))
    out.sort()
    return out


def ckpt_step(path):
    """Step stored in an engine checkpoint, else None.  Version 2 = engine/README.md; version 3 =
    the runs/memB_src engine (version 2 + an int32 lipid-architecture code before the step).
    Unknown versions (e.g. a GPU engine with its own format) give None; callers then use
    stats.csv, the snapshots and the 'done at step' lines of log.txt instead."""
    try:
        with open(path, "rb") as f:
            b = f.read(32)
        if len(b) == 32 and b[:4] == b"OCKP":
            ver = struct.unpack_from("<i", b, 4)[0]
            off = {2: 20, 3: 24}.get(ver)
            if off is not None:
                st = struct.unpack_from("<q", b, off)[0]
                return st if 0 <= st < 1 << 50 else None
    except OSError:
        pass
    return None


def ckpt_info(rundir):
    """(step or None, mtime or None) of rundir/ckpt.bin."""
    p = os.path.join(rundir, "ckpt.bin")
    if not os.path.exists(p):
        return None, None
    return ckpt_step(p), os.path.getmtime(p)


def tail_text(path, nbytes=65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            sz = f.tell()
            f.seek(max(0, sz - nbytes))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def stats_last(rundir):
    """Last complete row of stats.csv as a dict (or None)."""
    p = os.path.join(rundir, "stats.csv")
    txt = tail_text(p, 8192)
    if not txt:
        return None
    try:
        with open(p, encoding="utf-8") as f:
            head = f.readline().strip().split(",")
    except OSError:
        return None
    lines = txt.split("\n")
    complete = lines[:-1] if not txt.endswith("\n") else lines
    for line in reversed(complete):
        f = line.strip().split(",")
        if len(f) == len(head) and f[0].isdigit():
            out = {}
            for k, v in zip(head, f):
                try:
                    out[k] = float(v) if any(c in v for c in ".eEn") else int(v)
                except ValueError:
                    out[k] = v
            return out
    return None


def log_state(rundir):
    """Parse the end of the engine log: last 'done at step' (and whether it stopped early),
    last ms/step and the last error line."""
    txt = tail_text(os.path.join(rundir, "log.txt"), 65536)
    done = None
    early = False
    for m in re.finditer(r"done at step (\d+)( \(stopped early)?", txt):
        done, early = int(m.group(1)), bool(m.group(2))
    ms = re.findall(r"([0-9.]+) ms/step\s*$", txt, re.M)
    errs = [l for l in txt.splitlines() if re.search(r"error|cannot|refus|truncated|failed", l, re.I)]
    return dict(done_step=done, stopped_early=early, ms_per_step=float(ms[-1]) if ms else None,
                last_error=errs[-1] if errs else None)


def clean_tmp_files(rundir):
    """Remove partial files a killed engine can leave behind (snap_*.bin.tmp, ckpt.bin.tmp, params.ini.new)."""
    n = 0
    for pat in ("*.bin.tmp", "params.ini.new"):
        for p in glob.glob(os.path.join(rundir, pat)):
            try:
                os.unlink(p)
                n += 1
            except OSError:
                pass
    return n


ENGINE_OUTPUTS = ("snap_*.bin", "snap_*.bin.tmp", "ckpt.bin", "ckpt.bin.tmp", "ckpt_*.bin", "stats.csv",
                  "events.csv", "params.ini", "params.ini.new", "params_before_*.ini", "log.txt")


def wipe_engine_outputs(rundir):
    """Fresh start in a directory that has no checkpoint: remove leftovers of a run that died before
    its first checkpoint (supervisor files are kept)."""
    n = 0
    for pat in ENGINE_OUTPUTS:
        for p in glob.glob(os.path.join(rundir, pat)):
            try:
                os.unlink(p)
                n += 1
            except OSError:
                pass
    return n


# ----------------------------------------------------------------------------- processes
try:  # loaded in the parent, so the forked child only calls an already resolved function
    _libc = ctypes.CDLL("libc.so.6", use_errno=True)
    _prctl = _libc.prctl
except (OSError, AttributeError):
    _prctl = None


def _set_pdeathsig():
    """In the child: get SIGTERM when the supervisor dies (even by kill -9), so the engine stops
    cleanly with a checkpoint instead of running on unsupervised."""
    if _prctl is not None:
        _prctl(1, signal.SIGTERM, 0, 0, 0)  # PR_SET_PDEATHSIG


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # zombie?
    try:
        with open(f"/proc/{int(pid)}/stat") as f:
            if f.read().split(")")[-1].split()[0] == "Z":
                return False
    except OSError:
        pass
    return True


def proc_cmdline(pid):
    try:
        with open(f"/proc/{int(pid)}/cmdline", "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except (OSError, ValueError):
        return []


def engine_pids_for(rundir):
    """PIDs of engine processes (any binary) currently writing into rundir."""
    rd = os.path.abspath(rundir)
    out = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            pid = int(os.path.basename(d))
        except ValueError:
            continue
        if pid == os.getpid():
            continue
        cl = proc_cmdline(pid)
        if len(cl) >= 3 and os.path.basename(cl[0]).startswith("oercel") and os.path.abspath(cl[2]) == rd:
            out.append(pid)
    return out


def stop_pids(pids, timeout=180):
    """SIGTERM (engine writes a checkpoint and stops), then SIGKILL after timeout."""
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    t0 = time.time()
    while time.time() - t0 < timeout and any(pid_alive(p) for p in pids):
        time.sleep(0.5)
    for p in pids:
        if pid_alive(p):
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass


def popen_child(cmd, err_path=None, env=None, cwd=None, stdout_too=False):
    """Start a child process that dies with us (PR_SET_PDEATHSIG). Call only from the main thread
    or from a thread that outlives the child (the death signal follows the creating thread).
    stderr (and stdout if stdout_too) is appended to err_path; the engine's stdout duplicates log.txt."""
    out = open(err_path, "ab") if err_path else subprocess.DEVNULL
    try:
        return subprocess.Popen(cmd, stdout=out if stdout_too else subprocess.DEVNULL,
                                stderr=out, stdin=subprocess.DEVNULL,
                                preexec_fn=_set_pdeathsig, env=env, cwd=cwd)
    finally:
        if err_path:
            out.close()


def trim_file(path, max_bytes=20 << 20, keep_bytes=2 << 20):
    """Keep a log file bounded: when it exceeds max_bytes, keep only its last keep_bytes."""
    try:
        if os.path.getsize(path) <= max_bytes:
            return
        with open(path, "rb") as f:
            f.seek(-keep_bytes, 2)
            data = f.read()
        with open(path + ".tmp", "wb") as f:
            f.write(b"[... ingekort ...]\n" + data)
        os.replace(path + ".tmp", path)
    except OSError:
        pass


class AlreadyRunning(Exception):
    def __init__(self, pid):
        super().__init__(f"al actief (pid {pid})")
        self.pid = pid


_BUSY = (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK)


def _flock(fd, op, path=""):
    # test hook: a file system without flock (only the run directories; the /tmp fallback works)
    if os.environ.get("OERCEL_TEST_NO_FLOCK") == "1" and not os.path.basename(os.path.dirname(path)).startswith("oercel-locks-"):
        raise OSError(errno.ENOLCK, "flock niet ondersteund (testmodus)")
    fcntl.flock(fd, op)


def _alt_lock_path(path):
    """Lock file on the Linux file system for a directory whose own file system has no working flock
    (possible on the Windows drive /mnt/c in WSL).  Locks only live as long as the processes, so /tmp
    (emptied at boot) is fine."""
    import hashlib
    d = os.path.join("/tmp", f"oercel-locks-{os.getuid()}")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, hashlib.sha1(os.path.abspath(path).encode()).hexdigest()[:20] + ".lock")


class DirLock:
    """Exclusive lock on a run or sweep directory (released automatically when the process dies)."""

    def __init__(self, directory, name=".pc_lock"):
        self.path = os.path.join(directory, name)
        self.fd = None

    def _try(self, path):
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            _flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, path)
        except OSError as e:
            if e.errno in _BUSY:
                try:
                    pid = os.read(fd, 64).decode().strip()
                except OSError:
                    pid = "?"
                os.close(fd)
                raise AlreadyRunning(pid)
            os.close(fd)
            raise
        return fd

    def acquire(self):
        try:
            fd = self._try(self.path)
        except AlreadyRunning:
            raise
        except OSError as e:   # no flock on this file system: lock a file in /tmp instead
            log(f"LET OP: bestandsvergrendeling werkt niet in {os.path.dirname(self.path)} ({e.strerror}); "
                f"vergrendeling via {_alt_lock_path(self.path)}")
            fd = self._try(_alt_lock_path(self.path))
            try:
                with open(self.path, "w") as f:
                    f.write(str(os.getpid()))
            except OSError:
                pass
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        os.fsync(fd)
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None


def _holder_of(p):
    """(held, pid) for lock file p; raises OSError when flock does not work there."""
    if not os.path.exists(p):
        return False, None
    try:
        fd = os.open(p, os.O_RDONLY)
    except OSError:
        return False, None
    try:
        try:
            _flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB, p)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False, None
        except OSError as e:
            if e.errno not in _BUSY:
                raise
        try:
            return True, int(os.read(fd, 64).decode().strip() or 0) or "?"
        except (OSError, ValueError):
            return True, "?"
    finally:
        os.close(fd)


def lock_holder(directory, name=".pc_lock"):
    """PID holding the lock of a directory, or None if nobody holds it."""
    p = os.path.join(directory, name)
    try:
        held, pid = _holder_of(p)
    except OSError:
        held, pid = False, None
        try:
            held, pid = _holder_of(_alt_lock_path(p))
        except OSError:
            pass
    return pid if held else None


def engine_threads_in_use(exclude_dirs=()):
    """(processes, threads) of all running oercel* engines (threads from their threads= argument)."""
    ex = {os.path.abspath(d) for d in exclude_dirs}
    n = t = 0
    for d in glob.glob("/proc/[0-9]*"):
        cl = proc_cmdline(os.path.basename(d))
        if len(cl) < 3 or not os.path.basename(cl[0]).startswith("oercel"):
            continue
        if any(os.path.abspath(cl[2]).startswith(x + os.sep) or os.path.abspath(cl[2]) == x for x in ex):
            continue
        th = [a.split("=", 1)[1] for a in cl[3:] if a.startswith("threads=")]
        try:
            t += int(th[-1]) if th else 1
        except ValueError:
            t += 1
        n += 1
    return n, t


def on_windows_drive(path):
    """True for paths on the Windows drives in WSL (/mnt/c/...): slow, and file locking may not work."""
    return re.match(r"^/mnt/[a-zA-Z](/|$)", os.path.abspath(path)) is not None


def detach(script, argv, logpath):
    """Re-start `script argv` in its own session (survives closing the terminal or the Claude
    session) with output appended to logpath; returns the child pid."""
    os.makedirs(os.path.dirname(logpath), exist_ok=True)
    with open(logpath, "ab") as out:
        p = subprocess.Popen([sys.executable, script] + argv + ["--_bg"], stdout=out, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True, cwd=CEL)
    return p.pid


def cpu_count():
    try:
        return len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return os.cpu_count() or 1


def loadavg():
    try:
        return os.getloadavg()
    except OSError:
        return (0.0, 0.0, 0.0)


_IS_WSL = None


def is_wsl():
    global _IS_WSL
    if _IS_WSL is None:
        try:
            with open("/proc/version") as f:
                _IS_WSL = "microsoft" in f.read().lower()
        except OSError:
            _IS_WSL = False
    return _IS_WSL


def _fake_bytes(var):
    fake = os.environ.get(var)
    if fake:
        try:
            with open(fake) as f:
                return int(float(f.read().strip()))
        except (OSError, ValueError):
            pass
    return None


def host_drive_free():
    """WSL2 only: free bytes on the Windows drive C:, where WSL normally keeps the distro's virtual disk
    (ext4.vhdx).  Inside WSL, statvfs shows the free space of that virtual disk (up to 1 TB), not of the
    Windows drive it grows on: when C: fills up, the virtual disk can be damaged.  None outside WSL."""
    v = _fake_bytes("OERCEL_TEST_HOST_FREE_FILE")   # test hook
    if v is not None:
        return v
    if not is_wsl() or not os.path.isdir("/mnt/c"):
        return None
    try:
        st = os.statvfs("/mnt/c")
        return st.f_bavail * st.f_frsize
    except OSError:
        return None


def disk_free_detail(path):
    """(free bytes, which disk limits it): the Linux file system of path, or in WSL2 the Windows drive C:
    when that has less free space (see host_drive_free)."""
    v = _fake_bytes("OERCEL_TEST_DISK_FREE_FILE")   # test hook: free bytes read from a file
    if v is None:
        try:
            st = os.statvfs(path)
            v = st.f_bavail * st.f_frsize
        except OSError:
            return None, None
    which = "schijf"
    h = host_drive_free()
    if h is not None and h < v and not on_windows_drive(path):
        v, which = h, "Windows-schijf C: (daar groeit de virtuele WSL-schijf)"
    return v, which


def disk_free(path):
    return disk_free_detail(path)[0]


# ----------------------------------------------------------------------------- engine chunks
def engine_command(binary, ini, rundir, overrides, threads, walltime, restart=None, ckpt_keep=True):
    """Command line of one engine chunk.  Everything except restart/threads/walltime is identical in
    every chunk, so the engine sees unchanged parameters at each restart (no params_before_*.ini)."""
    cmd = [binary, ini, rundir]
    for k, v in overrides.items():
        cmd.append(f"{k}={v}")
    cmd.append(f"threads={int(threads)}")
    if ckpt_keep:
        cmd.append("ckpt_keep=1")
    if walltime:
        cmd.append(f"walltime={int(walltime)}")
    if restart:
        cmd.append(f"restart={restart}")
    return cmd


def restart_candidates(rundir):
    """Checkpoints to resume from, newest first: ckpt.bin, then the kept ckpt_<step>.bin copies."""
    out = []
    p = os.path.join(rundir, "ckpt.bin")
    if os.path.exists(p):
        out.append(p)
    for _, c in reversed(list_ckpt_copies(rundir)):
        out.append(c)
    return out


def current_step(rundir):
    """Best estimate of how far a run is: last stats row, newest complete snapshot, checkpoint."""
    best = 0
    s = stats_last(rundir)
    if s and isinstance(s.get("step"), int):
        best = max(best, s["step"])
    sn = list_snaps(rundir)
    if sn:
        best = max(best, sn[-1][0])
    c, _ = ckpt_info(rundir)
    if c:
        best = max(best, c)
    return best


def durable_step(rundir):
    """Step of the newest checkpoint (the progress that survives a crash); without a readable
    checkpoint format the best other estimate."""
    c, _ = ckpt_info(rundir)
    return c if c is not None else current_step(rundir)


def is_finished(rundir, target):
    """The engine reached `target` (absolute step)."""
    c, _ = ckpt_info(rundir)
    if c is not None and c >= target:
        return True
    ls = log_state(rundir)
    return ls["done_step"] is not None and ls["done_step"] >= target and not ls["stopped_early"]


# ----------------------------------------------------------------------------- analysis results
def analysis_summary(rundir, with_cells=True):
    """Numbers from tools/analyze.py output (checklist.json, lineage.json, cells.json) or None."""
    ck = read_json(os.path.join(rundir, "checklist.json"))
    if ck is None:
        return None
    lin = read_json(os.path.join(rundir, "lineage.json"), {}) or {}
    out = dict(snapshots=ck.get("snapshots"), step_last=ck.get("stap_laatste"), tracks=ck.get("sporen"),
               checklist=[], n_ja=0, n_deels=0, synthetic=bool(ck.get("synthetisch")),
               caveats=ck.get("kanttekeningen", []))
    for c in ck.get("criteria", []):
        out["checklist"].append(dict(id=c.get("id"), naam=c.get("naam"), status=c.get("status"),
                                     samenvatting=c.get("samenvatting", "")))
        out["n_ja"] += c.get("status") == "ja"
        out["n_deels"] += c.get("status") == "deels"
    ev = lin.get("events", []) or []
    dl = [e for e in ev if e.get("kind") == "deling"]
    out["divisions"] = len(dl)
    out["divisions_confirmed"] = sum(1 for e in dl if e.get("confirmed"))
    out["division_steps"] = sorted({int(e["step"]) for e in dl if "step" in e})
    out["fusions"] = sum(1 for e in ev if e.get("kind") == "fusie")
    out["max_generation"] = lin.get("max_generation", 0)
    out["n_tracks"] = len(lin.get("tracks", []) or [])
    if with_cells:
        cj = read_json(os.path.join(rundir, "cells.json"))
        if cj and cj.get("frames"):
            fr = cj["frames"]
            ncell = [len(f.get("cells", [])) for f in fr]
            ncat = [sum(1 for c in f.get("cells", []) if (c.get("n_Ka", 0) + c.get("n_Kb", 0)) > 0) for f in fr]
            out.update(cells_last=ncell[-1], cells_max=max(ncell), cat_cells_last=ncat[-1], cat_cells_max=max(ncat),
                       frame_step_last=fr[-1].get("step"))
            last = fr[-1].get("cells", [])
            out["kb_cells_last"] = sum(1 for c in last if c.get("n_Kb", 0) > 0)
    return out


def interesting_track(rundir):
    """(track id, step) of the most interesting cell for a Goodsell picture: dividing or daughter
    cells first, then catalysts, generation, lifetime and size.  Uses the last observation."""
    lin = read_json(os.path.join(rundir, "lineage.json"))
    if not lin or not lin.get("tracks"):
        return None
    best, bkey = None, None
    for t in lin["tracks"]:
        s = t.get("series", {})
        if not s.get("step"):
            continue
        cat = (s["n_Ka"][-1] if s.get("n_Ka") else 0) + (s["n_Kb"][-1] if s.get("n_Kb") else 0)
        key = (bool(t.get("children")) or bool(t.get("parents")), cat > 0, t.get("generation") or 0,
               t.get("n_frames", 0), cat, s["n_lipids"][-1] if s.get("n_lipids") else 0)
        if bkey is None or key > bkey:
            best, bkey = (t["id"], s["step"][-1]), key
    return best
