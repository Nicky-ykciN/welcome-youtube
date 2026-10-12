#!/bin/bash
# Crash test for pc/sweep.py: 8 small jobs (2 variants x 2-value grid x 2 seeds), 2 at a time, 1 thread.
#   a) kill -9 one ENGINE mid-chunk                -> the sweep restarts that job from its checkpoint
#   b) kill -9 the SWEEP SUPERVISOR mid-run        -> its engines stop with a checkpoint (PDEATHSIG)
#   c) re-run the same command                    -> every job continues and finishes, all are analysed
# Then: two jobs (including the killed one) are re-run directly with the engine, uninterrupted, and
# must be bitwise identical; SAMENVATTING.md / samenvatting.csv must rank all 8 jobs.
# usage: pc/tests/test_sweep_kill.sh [outdir]      (default pc/_test/sweep; ~3 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/sweep}
RUNS=$OUT/runs
SD=$RUNS/t_sweep
rm -rf "$OUT"; mkdir -p "$OUT"
cat > $OUT/jobs.txt <<'EOF'
# test sweep (small)
naam = t_sweep
basis = notes/membranen/teamA_membranes.ini
seeds = 1-2
zet = L=40 steps=30000 snap_every=1000 ckpt_every=2000 log_every=10000
raster a_N_T = 60 65
[stijf]
k_angle = 30
[zacht]
k_angle = 10
EOF
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
pids_in() {  # engine pids writing below $SD
  for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < $p/cmdline 2>/dev/null) || continue
    case "$c" in *oercel*" $(realpath $SD)/"*) echo -n "${p#/proc/} ";; esac
  done
}
job_of() { tr '\0' '\n' < /proc/$1/cmdline | sed -n 3p | xargs basename; }
step_of() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.current_step('$SD/$1'))"; }
CMD="python3 pc/sweep.py $OUT/jobs.txt --runs-dir $RUNS --jobs 2 --threads 1 --chunk-min 0.1 --poll 0.5 --achtergrond"

$CMD
sleep 3
E=$(pids_in | awk '{print $1}'); J=$(job_of $E)
t=0; while [ "$(step_of $J)" -lt 9000 ] && [ $t -lt 120 ]; do sleep 0.5; t=$((t + 1)); done
echo "  a) kill -9 engine $E of job $J at step $(step_of $J)"
kill -9 $E
sleep 20
S=$(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.lock_holder('$SD'))")
EE=$(pids_in)
echo "  b) kill -9 sweep supervisor $S (engines: $EE)"
kill -9 $S
t=0; while [ -n "$(pids_in)" ] && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
[ -z "$(pids_in)" ] && pass "engines stopped after the sweep supervisor was killed" || fail "engines still running: $(pids_in)"
for p in $EE; do :; done
echo "  c) same command again"
$CMD
t=0
while [ -n "$(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.lock_holder('$SD') or '')")" ]; do
  sleep 2; t=$((t + 1)); [ $t -gt 240 ] && { fail "sweep did not finish"; break; }
  n=$(pids_in | wc -w); [ "$n" -gt 2 ] && fail "more than 2 engines running ($n)"
done
python3 - $SD <<'EOF' || fails=$((fails + 1))
import json, sys
st = json.load(open(sys.argv[1] + '/pc_sweep.json'))
s = {n: v['status'] for n, v in st['state'].items()}
cr = {n: v['crashes'] for n, v in st['state'].items() if v.get('crashes')}
print('  job states:', sorted(set(s.values())), ' crashes:', cr)
ok = len(s) == 8 and all(v == 'geanalyseerd' for v in s.values()) and sum(cr.values()) >= 1
print(('PASS' if ok else 'FAIL') + '  all 8 jobs finished and analysed; the killed engine was counted as a crash')
sys.exit(0 if ok else 1)
EOF
echo "== uninterrupted reference runs =="
for J2 in $J zacht_a_N_T-65_s2; do
  OV=$(python3 -c "
import json; st=json.load(open('$SD/pc_sweep.json'))
j=[j for j in st['jobs'] if j['name']=='$J2'][0]; print(' '.join(f'{k}={v}' for k,v in j['overrides'].items()))")
  engine/oercel $SD/pc_base.ini $OUT/ref_$J2 $OV threads=1 >/dev/null
  ok=1
  for f in stats.csv ckpt.bin $(cd $OUT/ref_$J2 && ls snap_*.bin); do cmp -s $OUT/ref_$J2/$f $SD/$J2/$f || { ok=0; echo "  differs: $J2/$f"; }; done
  [ $ok = 1 ] && pass "job $J2: stats.csv, final checkpoint and all snapshots identical to an uninterrupted run" || fail "job $J2 differs"
done
n=$(grep -c '^| [0-9]' $SD/SAMENVATTING.md)
[ "$n" -ge 12 ] && pass "SAMENVATTING.md ranks jobs and variants ($n table rows)" || fail "SAMENVATTING.md has $n rows"
[ "$(tail -n +2 $SD/samenvatting.csv | wc -l)" = 8 ] && pass "samenvatting.csv has 8 jobs" || fail "samenvatting.csv"
sed -n 1,40p $SD/SAMENVATTING.md
echo "== summary: $fails failed check(s) =="
exit $fails
