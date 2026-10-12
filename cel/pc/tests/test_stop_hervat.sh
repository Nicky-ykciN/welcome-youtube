#!/bin/bash
# Stop / resume semantics and small guards (CPU engine, 1 thread, small boxes):
#   1. SIGTERM straight to a supervisor (what WSL/Windows does when it shuts down) -> state 'gestopt'
#      by 'signaal'; status.py calls it ONDERBROKEN and `status.py --hervat` brings it back
#   2. `longrun.py NAAM --stop` (deliberate) -> 'gestopt' by 'gebruiker'; `status.py --hervat` leaves it
#      alone and lists it with its command; the same for `sweep.py --stop` versus a SIGTERM
#   3. changing --steps of a RUNNING run is refused loudly (exit 1, "NIET TOEGEPAST") instead of ignored
#   4. a file system without working flock (simulated): the lock falls back to /tmp, a second start
#      sees the running supervisor, status.py sees it, --stop works
#   5. sweep with the disk (simulated) almost full: running engines stop cleanly with a checkpoint,
#      no crash is counted, nothing runs while the disk is full, and the jobs finish when space is back
#      (bitwise identical to an uninterrupted run)
# usage: pc/tests/test_stop_hervat.sh [outdir]     (default pc/_test/stop; ~3-4 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/stop}
rm -rf "$OUT"; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd); RUNS=$OUT/runs
export OERCEL_NO_BUILD=1
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
INI=engine/params/soup_small.ini
py() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; $1"; }
lst() { python3 -c "import json; print(json.load(open('$RUNS/$1/pc_longrun.json')).get('$2'))"; }
holder() { py "print(P.lock_holder('$1') or '')"; }
waitgone() { local t=0; while [ -n "$(holder $1)" ] && [ $t -lt 240 ]; do sleep 0.5; t=$((t + 1)); done; }
OV="L=32 steps=2000000 snap_every=20000 ckpt_every=2000 log_every=100000"
LR="--engine cpu --threads 1 --chunk-min 0.3 --analyse-uur 0 --geen-beelden --analyse-jobs 1 --poll 0.3 --runs-dir $RUNS"

echo "== 1. SIGTERM from outside (shutdown) =="
python3 pc/longrun.py r1 --ini $INI --set $OV $LR --achtergrond > /dev/null
sleep 3
kill -TERM "$(holder $RUNS/r1)"; waitgone $RUNS/r1
[ "$(lst r1 status)" = gestopt ] && [ "$(lst r1 stopped_by)" = signaal ] && pass "state gestopt by 'signaal'" || fail "state $(lst r1 status)/$(lst r1 stopped_by)"
python3 pc/status.py --runs-dir $RUNS > $OUT/s1.txt
grep -q "r1 .*ONDERBROKEN" $OUT/s1.txt && pass "status.py: ONDERBROKEN" || { fail "status.py"; cat $OUT/s1.txt; }
python3 pc/status.py --runs-dir $RUNS --hervat > $OUT/h1.txt
sleep 2
[ -n "$(holder $RUNS/r1)" ] && pass "status.py --hervat resumed it" || { fail "not resumed"; cat $OUT/h1.txt; }

echo "== 3. --steps on a running run =="
python3 pc/longrun.py r1 --steps 3000000 --runs-dir $RUNS > $OUT/steps.txt 2>&1; rc=$?
[ $rc = 1 ] && grep -q "NIET TOEGEPAST" $OUT/steps.txt && pass "refused with exit 1: $(grep -o 'NIET TOEGEPAST.*' $OUT/steps.txt | cut -c1-90)" || { fail "rc=$rc"; cat $OUT/steps.txt; }
[ "$(lst r1 steps)" = 2000000 ] && pass "target unchanged" || fail "target $(lst r1 steps)"
python3 pc/longrun.py r1 --runs-dir $RUNS --achtergrond > $OUT/same.txt 2>&1 && grep -q "draait al" $OUT/same.txt && pass "plain resume of a running run: 'draait al', exit 0" || fail "plain resume"

echo "== 2. deliberate --stop =="
python3 pc/longrun.py r1 --stop --runs-dir $RUNS > /dev/null
[ "$(lst r1 status)" = gestopt ] && [ "$(lst r1 stopped_by)" = gebruiker ] && pass "state gestopt by 'gebruiker'" || fail "state $(lst r1 status)/$(lst r1 stopped_by)"
cat > $OUT/jobs.txt <<'EOF'
naam = sw1
basis = notes/membranen/teamA_membranes.ini
seeds = 1-2
zet = L=32 steps=2000000 snap_every=50000 ckpt_every=2000 log_every=100000
EOF
SW="python3 pc/sweep.py $OUT/jobs.txt --runs-dir $RUNS --jobs 1 --threads 1 --chunk-min 0.3 --poll 0.3 --achtergrond"
$SW > /dev/null; sleep 3
python3 pc/sweep.py --stop sw1 --runs-dir $RUNS > /dev/null
python3 -c "import json; s=json.load(open('$RUNS/sw1/pc_sweep.json')); assert s['supervisor_state']=='gestopt' and s['stopped_by']=='gebruiker', s.get('stopped_by')" \
  && pass "sweep --stop: gestopt by 'gebruiker'" || fail "sweep state"
python3 pc/status.py --runs-dir $RUNS --hervat > $OUT/h2.txt; sleep 2
[ -z "$(holder $RUNS/r1)" ] && [ -z "$(holder $RUNS/sw1)" ] && pass "status.py --hervat leaves deliberately stopped runs/sweeps alone" || fail "something was resumed"
grep -A3 "BEWUST GESTOPT" $OUT/h2.txt | grep -q "longrun.py r1" && grep -A3 "BEWUST GESTOPT" $OUT/h2.txt | grep -q "sweep.py --hervat sw1" \
  && pass "both listed under BEWUST GESTOPT with their command" || { fail "listing"; cat $OUT/h2.txt; }
$SW > /dev/null; sleep 3
kill -TERM "$(holder $RUNS/sw1)"; waitgone $RUNS/sw1
python3 pc/status.py --runs-dir $RUNS --hervat > $OUT/h3.txt; sleep 2
[ -n "$(holder $RUNS/sw1)" ] && [ -z "$(holder $RUNS/r1)" ] && pass "sweep stopped by a SIGTERM is resumed by --hervat, the stopped run is not" || { fail "h3"; cat $OUT/h3.txt; }
python3 pc/sweep.py --stop sw1 --runs-dir $RUNS > /dev/null

echo "== 4. no flock on the file system (simulated) =="
export OERCEL_TEST_NO_FLOCK=1
python3 pc/longrun.py r2 --ini $INI --set $OV $LR --achtergrond > /dev/null
sleep 3
h=$(holder $RUNS/r2)
[ -n "$h" ] && pass "lock held via the fallback file in /tmp (pid $h)" || fail "no lock holder seen"
grep -q "vergrendeling via /tmp/oercel-locks" $RUNS/r2/pc_supervisor.log $RUNS/r2/pc_supervisor.out 2>/dev/null && pass "fallback logged" || fail "fallback not logged"
python3 pc/longrun.py r2 --runs-dir $RUNS > $OUT/r2b.txt 2>&1
grep -q "draait al" $OUT/r2b.txt && [ "$(py "print(len(P.engine_pids_for('$RUNS/r2')))")" = 1 ] && pass "second start refused, one engine" || { fail "second start"; cat $OUT/r2b.txt; }
python3 pc/longrun.py r2 --stop --runs-dir $RUNS > /dev/null
[ -z "$(holder $RUNS/r2)" ] && [ "$(lst r2 status)" = gestopt ] && pass "--stop works with the fallback lock" || fail "stop: $(lst r2 status)"
unset OERCEL_TEST_NO_FLOCK

echo "== 5. sweep: disk almost full =="
export OERCEL_TEST_DISK_FREE_FILE=$OUT/free_bytes OERCEL_TEST_HOST_FREE_FILE=$OUT/free_bytes   # (WSL2: C: too)
echo 100000000000 > $OERCEL_TEST_DISK_FREE_FILE
cat > $OUT/jobs2.txt <<'EOF'
naam = sw2
basis = notes/membranen/teamA_membranes.ini
seeds = 1-2
zet = L=32 steps=120000 snap_every=5000 ckpt_every=1000 log_every=100000
EOF
python3 pc/sweep.py $OUT/jobs2.txt --runs-dir $RUNS --jobs 2 --threads 1 --chunk-min 1 --poll 0.3 --achtergrond > /dev/null
sleep 4
echo 5000000000 > $OERCEL_TEST_DISK_FREE_FILE
t=0; while [ -n "$(py "print(P.engine_pids_for('$RUNS/sw2/basis_s1') + P.engine_pids_for('$RUNS/sw2/basis_s2') or '')")" ] && [ $t -lt 120 ]; do sleep 0.5; t=$((t + 1)); done
[ -z "$(py "print(P.engine_pids_for('$RUNS/sw2/basis_s1') + P.engine_pids_for('$RUNS/sw2/basis_s2') or '')")" ] && pass "running engines stopped when the disk got full" || fail "engines still running"
grep -q "stopping at step .* (signal)" $RUNS/sw2/basis_s1/log.txt && pass "engine stopped with a checkpoint" || fail "no clean stop"
a1=$(py "print(P.current_step('$RUNS/sw2/basis_s1'))"); sleep 5; a2=$(py "print(P.current_step('$RUNS/sw2/basis_s1'))")
[ "$a1" = "$a2" ] && pass "no progress while the disk is full ($a1)" || fail "progress $a1 -> $a2"
python3 -c "import json; s=json.load(open('$RUNS/sw2/pc_sweep.json')); c=[v['crashes'] for v in s['state'].values()]; assert sum(c)==0, c" \
  && pass "pausing is not counted as a crash" || fail "crashes counted"
echo 100000000000 > $OERCEL_TEST_DISK_FREE_FILE
waitgone $RUNS/sw2
python3 -c "import json; s=json.load(open('$RUNS/sw2/pc_sweep.json')); v=sorted(x['status'] for x in s['state'].values()); assert v==['geanalyseerd']*2, v" \
  && pass "both jobs finished and analysed after space came back" || fail "sweep not finished"
OVJ=$(python3 -c "
import json; st=json.load(open('$RUNS/sw2/pc_sweep.json'))
j=[j for j in st['jobs'] if j['name']=='basis_s1'][0]; print(' '.join(f'{k}={v}' for k,v in j['overrides'].items()))")
engine/oercel $RUNS/sw2/pc_base.ini $OUT/ref_s1 $OVJ threads=1 > /dev/null
ok=1; for f in stats.csv ckpt.bin snap_0000120000.bin; do cmp -s $OUT/ref_s1/$f $RUNS/sw2/basis_s1/$f || { ok=0; echo "  differs: $f"; }; done
[ $ok = 1 ] && pass "job bitwise identical to an uninterrupted run" || fail "job differs"
unset OERCEL_TEST_DISK_FREE_FILE OERCEL_TEST_HOST_FREE_FILE
echo "== summary: $fails failed check(s) =="
exit $fails
