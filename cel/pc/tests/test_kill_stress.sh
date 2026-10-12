#!/bin/bash
# kill -9 at awkward moments (pc/longrun.py and pc/sweep.py, CPU engine, 1 thread, small boxes):
#   A. long run: kill -9 of the engine WHILE it writes ckpt.bin.tmp (several times), of the engine while
#      it writes a snapshot, of the supervisor while the engine writes a checkpoint (the engine then gets
#      SIGTERM mid-write), of supervisor + engine together during a checkpoint write (power cut), and
#      a few random kills -> the final stats.csv, events.csv, ckpt.bin and every snapshot must be bitwise
#      identical to an uninterrupted run; no *.tmp left; checkpoint copies stay bounded.
#   B. long run with analysis every ~4 s, thinning (keep-recent 4, max-stride 4) and images: kill -9 of
#      the supervisor while tools/analyze.py or tools/render.py runs (and during the thinning that
#      follows) -> the run finishes, its analysis files are valid JSON, no half PNG (*.tmp.png) in beelden/,
#      the analysis cache only covers existing snapshots, and every remaining snapshot + the final
#      checkpoint are bitwise identical to an uninterrupted run.
#   C. sweep: kill -9 of the sweep supervisor at random moments, also while jobs are being analysed;
#      the same command resumes; every job ends analysed and two jobs are bitwise identical.
# usage: pc/tests/test_kill_stress.sh [outdir]     (default pc/_test/stress; ~6-10 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/stress}
rm -rf "$OUT"; mkdir -p "$OUT/a" "$OUT/b" "$OUT/c"
OUT=$(cd "$OUT" && pwd)
export OERCEL_NO_BUILD=1
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
INI=engine/params/soup_small.ini
py() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; $1"; }

# kill_when RUNDIR PATTERN WHO [timeout]: wait until a file matching PATTERN exists in RUNDIR, then kill -9
# WHO (engine | sup | both) of that run at once; prints what happened (and whether the file was still there)
cat > $OUT/kill_when.py <<'EOF'
import glob, os, signal, sys, time
sys.path.insert(0, 'pc')
import pclib as P
rd, pat, who = sys.argv[1], sys.argv[2], sys.argv[3]
tmo = float(sys.argv[4]) if len(sys.argv) > 4 else 20
t1 = time.time() + tmo
eng = P.engine_pids_for(rd)
sup = P.lock_holder(rd)
n = 0
while time.time() < t1:
    n += 1
    if n % 300 == 0 or not eng:          # the supervisor may have started a new engine (new chunk)
        eng = P.engine_pids_for(rd)
        sup = P.lock_holder(rd)
    if eng and glob.glob(os.path.join(rd, pat)):
        pids = (eng if who in ("engine", "both") else []) + ([int(sup)] if who in ("sup", "both") and sup not in (None, "?") else [])
        for p in pids:
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        still = bool(glob.glob(os.path.join(rd, pat)))
        print(f"  kill -9 {who} {pids} while {pat} existed (still there right after the kill: {still})")
        sys.exit(0 if still else 3)
    time.sleep(0.0003)
print(f"  {pat} not seen within {tmo} s")
sys.exit(2)
EOF

# ------------------------------------------------------------------------------------------------ A
echo "== A. long run: kills during checkpoint and snapshot writes =="
RA=$OUT/a/runs; RD=$RA/s1
OV="L=32 steps=240000 snap_every=500 ckpt_every=1000 stats_every=100 log_every=50000"
engine/oercel $INI $OUT/a/ref $OV threads=1 > /dev/null
START="python3 pc/longrun.py s1 --runs-dir $RA --beelden-dir $OUT/a/beelden --achtergrond"
$START --ini $INI --set $OV --engine cpu --threads 1 --chunk-min 0.2 --analyse-uur 0 --geen-beelden --analyse-jobs 1 \
  --poll 0.3 --backoff 0.2 --keep-recent 100000 > /dev/null
sleep 2
hits=0
waitrun() {  # wait until the supervisor and an engine run again
  local t=0
  while { [ -z "$(py "print(P.lock_holder('$RD') or '')")" ] || [ -z "$(py "print(P.engine_pids_for('$RD') or '')")" ]; } && [ $t -lt 120 ]; do
    sleep 0.3; t=$((t + 1))
    [ "$(python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['status'])")" = klaar ] && return 1
  done
  return 0
}
for k in engine engine engine engine snap sup engine both both sup both engine; do
  waitrun || break
  sleep 0.$((RANDOM % 9 + 1))
  case $k in
    engine) python3 $OUT/kill_when.py $RD 'ckpt.bin.tmp' engine && hits=$((hits + 1)) ;;
    snap)   python3 $OUT/kill_when.py $RD 'snap_*.bin.tmp' engine ;;
    sup)    python3 $OUT/kill_when.py $RD 'ckpt.bin.tmp' sup && hits=$((hits + 1)); sleep 1.5; $START > /dev/null ;;
    both)   python3 $OUT/kill_when.py $RD 'ckpt.bin.tmp' both && hits=$((hits + 1)); sleep 0.5; $START > /dev/null ;;
  esac
  n=$(py "print(len(P.engine_pids_for('$RD')))"); [ "$n" -gt 1 ] && fail "two engines on one directory"
done
for r in 1 2 3; do  # random moments
  waitrun || break
  sleep $((RANDOM % 3)).$((RANDOM % 10))
  E=$(py "print(' '.join(map(str, P.engine_pids_for('$RD'))))"); echo "  random kill -9 engine $E"; kill -9 $E 2>/dev/null
done
waitrun
t=0; while [ "$(python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['status'])")" != klaar ] && [ $t -lt 600 ]; do
  sleep 1; t=$((t + 1))
  [ -z "$(py "print(P.lock_holder('$RD') or '')")" ] && $START > /dev/null    # a supervisor kill may have been the last action
done
echo "  $hits kills landed while ckpt.bin.tmp was being written"
[ $hits -ge 3 ] && pass "at least 3 kills during a checkpoint write ($hits)" || fail "only $hits kills during a checkpoint write (timing)"
st=$(python3 -c "import json; s=json.load(open('$RD/pc_longrun.json')); print(s['status'], s['chunks'], s['crashes'], s.get('bad_ckpts'))")
echo "  state: status chunks crashes bad_ckpts = $st"
ok=1
for f in stats.csv events.csv ckpt.bin; do cmp -s $OUT/a/ref/$f $RD/$f || { ok=0; echo "  DIFFERENT: $f"; }; done
ns=0; for s in $OUT/a/ref/snap_*.bin; do ns=$((ns + 1)); cmp -s $s $RD/$(basename $s) || { ok=0; echo "  DIFFERENT/MISSING: $(basename $s)"; }; done
[ $ok = 1 ] && pass "stats.csv, events.csv, final checkpoint and all $ns snapshots bitwise identical" || fail "outputs differ from the uninterrupted run"
[ -z "$(ls $RD/*.tmp* 2>/dev/null)" ] && pass "no half-written files left" || fail "left: $(ls $RD/*.tmp*)"
nc=$(ls $RD/ckpt_*.bin 2>/dev/null | wc -l); [ "$nc" -le 4 ] && pass "checkpoint copies bounded ($nc)" || fail "$nc checkpoint copies"

# ------------------------------------------------------------------------------------------------ B
echo "== B. long run: kills during analysis, rendering and thinning =="
RB=$OUT/b/runs; RD=$RB/t1
OV="L=40 steps=150000 snap_every=1000 ckpt_every=2000 stats_every=100 log_every=50000"
engine/oercel $INI $OUT/b/ref $OV threads=1 > /dev/null
STARTB="python3 pc/longrun.py t1 --runs-dir $RB --beelden-dir $OUT/b/beelden --achtergrond"
$STARTB --ini $INI --set $OV --engine cpu --threads 1 --chunk-min 0.3 --analyse-uur 0.001 --analyse-jobs 1 --width 500 \
  --images-keep 2 --keep-recent 4 --max-stride 4 --poll 0.3 --backoff 0.2 > /dev/null
nk=0; nr=0
for i in $(seq 1 9); do
  # wait for a running analyze.py (first 5 kills) or render.py (last 4) of this run, then kill -9 the supervisor
  tool=analyze.py; [ $i -gt 5 ] && tool=render.py
  r=$(python3 - "$RD" "$tool" <<'EOF'
import os, sys, time, signal
sys.path.insert(0, 'pc')
import pclib as P
rd = os.path.abspath(sys.argv[1])
tool = sys.argv[2]
t1 = time.time() + 60
while time.time() < t1:
    sup = P.lock_holder(rd)
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        cl = P.proc_cmdline(int(d))
        if len(cl) >= 3 and cl[1].endswith(tool) and os.path.abspath(cl[2]) == rd and sup not in (None, '?'):
            time.sleep(0.05 + (time.time() * 1000 % 7) / 10)   # somewhere inside the tool
            os.kill(int(sup), signal.SIGKILL)
            print(os.path.basename(cl[1]))
            sys.exit(0)
    time.sleep(0.02)
print('none')
EOF
)
  [ "$r" = none ] && break
  nk=$((nk + 1)); [ "$r" = render.py ] && nr=$((nr + 1)); echo "  kill -9 supervisor during $r"
  sleep 1
  $STARTB > /dev/null
done
[ $nk -ge 6 ] && [ $nr -ge 2 ] && pass "$nk supervisor kills during analysis/rendering ($nr during render.py)" || fail "only $nk kills ($nr during render.py)"
t=0; while [ "$(python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['status'])")" != klaar ] && [ $t -lt 600 ]; do
  sleep 1; t=$((t + 1)); [ -z "$(py "print(P.lock_holder('$RD') or '')")" ] && $STARTB > /dev/null
done
python3 - "$RD" "$OUT/b" <<'EOF' || fails=$((fails + 1))
import glob, json, os, sys
sys.path.insert(0, 'pc')
import pclib as P
rd, ob = sys.argv[1], sys.argv[2]
bad = 0
def check(ok, msg):
    global bad
    print(('PASS  ' if ok else 'FAIL  ') + msg)
    bad += not ok
st = json.load(open(rd + '/pc_longrun.json'))
check(st['status'] == 'klaar', f"status {st['status']} after {st['chunks']} chunks")
for f in ('cells.json', 'lineage.json', 'checklist.json'):
    try:
        json.load(open(os.path.join(rd, f)))
        ok = True
    except Exception as e:
        ok = False
    check(ok, f"{f} is valid JSON")
steps = [s for s, _ in P.list_snaps(rd)]
check(len(steps) < 151 and 0 in steps and 150000 in steps, f"thinned to {len(steps)} snapshots (first and last kept)")
cache = {int(os.path.basename(p)[6:16]) for p in glob.glob(rd + '/analysis_cache/cells_*.json')}
check(cache <= set(steps), f"analysis cache only for existing snapshots ({len(cache)} entries, {len(cache - set(steps))} stale)")
tmp = glob.glob(os.path.join(ob, 'beelden', '*', '*.tmp.png'))
check(not tmp, f"no half images in beelden/ ({tmp})")
imgs = st.get('images', {})
on_disk = sorted(glob.glob(os.path.join(ob, 'beelden', 't1', '*.png')))
check(set(on_disk) == {p for v in imgs.values() for p in v}, f"beelden/t1 holds exactly the {len(on_disk)} images listed in the state")
same = all(open(p, 'rb').read() == open(os.path.join(ob, 'ref', os.path.basename(p)), 'rb').read() for _, p in P.list_snaps(rd))
check(same, f"all {len(steps)} remaining snapshots bitwise identical to the uninterrupted run")
check(open(rd + '/ckpt.bin', 'rb').read() == open(ob + '/ref/ckpt.bin', 'rb').read(), "final checkpoint identical")
check(open(rd + '/stats.csv').read() == open(ob + '/ref/stats.csv').read(), "stats.csv identical")
sys.exit(bad)
EOF

# ------------------------------------------------------------------------------------------------ C
echo "== C. sweep: supervisor kills at random moments (also during analyses) =="
SC=$OUT/c; RC=$SC/runs; SD=$RC/st_sweep
cat > $SC.jobs.txt <<'EOF'
naam = st_sweep
basis = notes/membranen/teamA_membranes.ini
seeds = 1-3
zet = L=32 steps=40000 snap_every=2000 ckpt_every=2000 log_every=20000
raster a_N_T = 60 65
EOF
CMD="python3 pc/sweep.py $SC.jobs.txt --runs-dir $RC --jobs 2 --threads 1 --chunk-min 0.1 --poll 0.3 --achtergrond"
$CMD > /dev/null
for i in $(seq 1 8); do
  sleep $((RANDOM % 4 + 1)).$((RANDOM % 10))
  S=$(py "print(P.lock_holder('$SD') or '')")
  [ -z "$S" ] && break
  what=$(for p in /proc/[0-9]*; do { tr '\0' ' ' < $p/cmdline; } 2>/dev/null; echo; done | grep -c "analyze.py $(realpath $SD)/")
  echo "  kill -9 sweep supervisor $S ($what analyses running)"
  kill -9 $S
  sleep 1
  $CMD > /dev/null
done
t=0
while [ -n "$(py "print(P.lock_holder('$SD') or '')")" ] && [ $t -lt 600 ]; do sleep 1; t=$((t + 1)); done
python3 - $SD <<'EOF' || fails=$((fails + 1))
import json, sys
st = json.load(open(sys.argv[1] + '/pc_sweep.json'))
s = sorted(v['status'] for v in st['state'].values())
ok = s == ['geanalyseerd'] * 6
print(('PASS' if ok else 'FAIL') + f'  all 6 jobs finished and analysed after the kills: {s}')
sys.exit(0 if ok else 1)
EOF
for J in a_N_T-60_s1 a_N_T-65_s3; do
  OVJ=$(python3 -c "
import json; st=json.load(open('$SD/pc_sweep.json'))
j=[j for j in st['jobs'] if j['name']=='$J'][0]; print(' '.join(f'{k}={v}' for k,v in j['overrides'].items()))")
  engine/oercel $SD/pc_base.ini $SC/ref_$J $OVJ threads=1 > /dev/null
  ok=1; for f in stats.csv ckpt.bin $(cd $SC/ref_$J && ls snap_*.bin); do cmp -s $SC/ref_$J/$f $SD/$J/$f || { ok=0; echo "  differs: $J/$f"; }; done
  [ $ok = 1 ] && pass "job $J bitwise identical to an uninterrupted run" || fail "job $J differs"
done
echo "== summary: $fails failed check(s) =="
exit $fails
