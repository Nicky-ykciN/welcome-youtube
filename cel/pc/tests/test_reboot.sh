#!/bin/bash
# "Reboot" test: a long run and a sweep are running in the background; then every supervisor and
# every engine is killed with kill -9 at the same moment (like a power cut or a Windows update
# reboot).  One command, `pc/status.py --hervat`, must bring both back; both must finish, and the
# long run must be bitwise identical to an uninterrupted engine run.
# usage: pc/tests/test_reboot.sh [outdir]     (default pc/_test/reboot; ~2 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/reboot}
RUNS=$OUT/runs
rm -rf "$OUT"; mkdir -p "$RUNS"
export OERCEL_NO_BUILD=1
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
INI=engine/params/soup_small.ini
OV="L=40 steps=40000 snap_every=1000 ckpt_every=2000 log_every=10000"
cat > $OUT/jobs.txt <<'X'
naam = rb_sweep
basis = notes/membranen/teamA_membranes.ini
seeds = 1-3
zet = L=32 steps=80000 snap_every=2000 ckpt_every=2000 log_every=10000
X
engine/oercel $INI $OUT/ref $OV threads=1 >/dev/null
python3 pc/longrun.py lr --ini $INI --set $OV --engine cpu --threads 1 --chunk-min 0.2 --analyse-uur 0 --analyse-jobs 1 \
  --width 600 --poll 0.5 --runs-dir $RUNS --beelden-dir $OUT/beelden --achtergrond >/dev/null
python3 pc/sweep.py $OUT/jobs.txt --runs-dir $RUNS --jobs 1 --threads 1 --chunk-min 0.2 --poll 0.5 --achtergrond >/dev/null
sleep 8
pids=$(python3 - $RUNS <<'X'
import glob, os, sys
sys.path.insert(0, 'pc')
import pclib as P
runs = sys.argv[1]
out = []
for d in [os.path.join(runs, 'lr'), os.path.join(runs, 'rb_sweep')]:
    h = P.lock_holder(d)
    if h and h != '?':
        out.append(int(h))
for d in [os.path.join(runs, 'lr')] + glob.glob(os.path.join(runs, 'rb_sweep', '*/')):
    out += P.engine_pids_for(d.rstrip('/'))
print(' '.join(map(str, sorted(set(out)))))
X
)
echo "  power cut: kill -9 $pids"
kill -9 $pids 2>/dev/null
sleep 1
python3 pc/status.py --runs-dir $RUNS > $OUT/status_before.txt
grep -q "ONDERBROKEN" $OUT/status_before.txt && pass "status.py reports the interrupted runs" || { fail "status.py"; cat $OUT/status_before.txt; }
python3 pc/status.py --runs-dir $RUNS --hervat | tail -8
t=0
while :; do
  a=$(python3 -c "import json; print(json.load(open('$RUNS/lr/pc_longrun.json'))['status'])")
  b=$(python3 -c "import json; s=json.load(open('$RUNS/rb_sweep/pc_sweep.json')); print(s.get('supervisor_state'))")
  [ "$a" = klaar ] && [ "$b" = klaar ] && break
  sleep 1; t=$((t + 1)); [ $t -gt 400 ] && { fail "not finished (longrun $a, sweep $b)"; break; }
done
ok=1; for f in stats.csv events.csv ckpt.bin snap_0000040000.bin; do cmp -s $OUT/ref/$f $RUNS/lr/$f || { ok=0; echo "  differs: $f"; }; done
[ $ok = 1 ] && pass "long run resumed by status.py --hervat and identical to the uninterrupted run" || fail "long run differs"
python3 - $RUNS/rb_sweep <<'X' || fails=$((fails + 1))
import json, sys
st = json.load(open(sys.argv[1] + '/pc_sweep.json'))
s = sorted(v['status'] for v in st['state'].values())
ok = s == ['geanalyseerd'] * 3
print(('PASS' if ok else 'FAIL') + f'  sweep resumed and finished: {s}')
sys.exit(0 if ok else 1)
X
python3 pc/status.py --runs-dir $RUNS --kort | tail -6
echo "== summary: $fails failed check(s) =="
exit $fails
