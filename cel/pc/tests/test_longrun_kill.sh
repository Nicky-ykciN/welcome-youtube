#!/bin/bash
# Crash test for pc/longrun.py (small CPU run, 1 thread):
#   1. reference: the engine runs uninterrupted (no supervisor)
#   2. supervised run in chunks; during it:
#        a) kill -9 of the ENGINE mid-chunk        -> supervisor restarts it from ckpt.bin
#        b) kill -9 of the SUPERVISOR              -> engine gets SIGTERM (PR_SET_PDEATHSIG), writes a
#                                                     checkpoint and stops; re-running the command resumes
#        c) kill -9 of supervisor AND engine at once (like a power cut / reboot) -> re-running resumes
#   3. stats.csv, events.csv, the final checkpoint and every snapshot present in both runs must be
#      bitwise identical to the reference; never two engines on the same directory.
# usage: pc/tests/test_longrun_kill.sh [outdir]      (default pc/_test/kill; ~2-3 minutes)
set -u
cd "$(dirname "$0")/../.."     # -> cel/
OUT=${1:-pc/_test/kill}
RUNS=$OUT/runs
NAME=k1
RD=$RUNS/$NAME
INI=engine/params/soup_small.ini
OV="L=48 steps=60000 snap_every=1000 ckpt_every=3000 stats_every=100 log_every=5000"
rm -rf "$OUT"; mkdir -p "$RUNS"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
step() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.current_step('$RD'))"; }
engines() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(' '.join(map(str, P.engine_pids_for('$RD'))))"; }
sup_pid() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.lock_holder('$RD') or '')"; }
wait_step() {  # wait until the run passed step $1 (max $2 s); also checks there is never more than one engine
  local t=0
  while [ "$(step)" -lt "$1" ]; do
    n=$(engines | wc -w); [ "$n" -gt 1 ] && fail "two engines on one directory: $(engines)"
    sleep 0.5; t=$((t + 1)); [ $t -gt $(( $2 * 2 )) ] && { echo "timeout waiting for step $1 (at $(step))"; return 1; }
  done
  return 0
}
start_sup() {
  python3 pc/longrun.py $NAME --runs-dir "$RUNS" --beelden-dir "$OUT/beelden" "$@" --achtergrond >/dev/null
  sleep 2
}

echo "== reference run (engine directly, uninterrupted) =="
engine/oercel $INI $OUT/ref $OV threads=1 >/dev/null || fail "reference run"

echo "== supervised run =="
start_sup --ini $INI --set $OV --engine cpu --threads 1 --chunk-min 0.15 --analyse-uur 0 --analyse-jobs 1 --width 800 --keep-recent 1000 --poll 1
wait_step 10000 120 || fail "no progress"
E=$(engines); echo "  a) kill -9 engine $E at step $(step)"
kill -9 $E
sleep 1
wait_step 25000 180 || fail "no progress after engine kill"
S=$(sup_pid); E=$(engines); echo "  b) kill -9 supervisor $S at step $(step) (engine $E should stop by itself)"
kill -9 $S
t=0; while [ -n "$(engines)" ] && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
[ -z "$(engines)" ] && pass "engine stopped after its supervisor was killed (PR_SET_PDEATHSIG)" || fail "engine $(engines) kept running without supervisor"
grep -q "stopping at step .* (signal)" $RD/log.txt && pass "engine wrote a checkpoint on the way out: $(grep 'stopping at step' $RD/log.txt | tail -1)" || fail "no clean stop in log.txt"
start_sup
wait_step 40000 180 || fail "no progress after supervisor restart"
S=$(sup_pid); E=$(engines); echo "  c) kill -9 supervisor $S and engine $E together at step $(step) (power cut)"
kill -9 $S $E
sleep 1
ls $RD/*.tmp 2>/dev/null && echo "  (half-written files left behind: $(ls $RD/*.tmp | wc -l))"
start_sup
t=0
while [ "$(python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['status'])")" != "klaar" ]; do
  sleep 1; t=$((t + 1)); [ $t -gt 300 ] && { fail "run did not finish"; break; }
  n=$(engines | wc -w); [ "$n" -gt 1 ] && fail "two engines on one directory"
done
sleep 1
echo "== compare with the reference =="
ok=1
for f in stats.csv events.csv ckpt.bin; do
  if cmp -s $OUT/ref/$f $RD/$f; then echo "  identical: $f"; else echo "  DIFFERENT: $f"; ok=0; fi
done
ns=0; nd=0
for s in $RD/snap_*.bin; do
  b=$(basename $s); ns=$((ns + 1))
  cmp -s $s $OUT/ref/$b || { nd=$((nd + 1)); echo "  DIFFERENT: $b"; }
done
[ $nd -eq 0 ] || ok=0
[ $ok = 1 ] && pass "stats.csv, events.csv, final checkpoint and all $ns snapshots bitwise identical to the uninterrupted run" || fail "outputs differ from the reference"
python3 - $RD <<'EOF'
import json, sys
st = json.load(open(sys.argv[1] + '/pc_longrun.json'))
print(f"  state: status={st['status']} chunks={st['chunks']} crashes={st['crashes']} last_crash={st.get('last_crash')}")
EOF
grep -c "ENGINE GESTOPT" $RD/pc_supervisor.log | xargs -I{} echo "  supervisor log: {} engine crash(es) handled"
[ -z "$(ls $RD/*.tmp 2>/dev/null)" ] && pass "no half-written files left" || fail "tmp files left: $(ls $RD/*.tmp)"
echo "== summary: $fails failed check(s) =="
exit $fails
