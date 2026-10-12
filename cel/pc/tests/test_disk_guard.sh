#!/bin/bash
# Disk-full guard of pc/longrun.py: when free space drops below --min-vrij-gb the engine is stopped
# cleanly (checkpoint) and the supervisor waits; when space comes back it continues by itself, and
# the result is still bitwise identical to an uninterrupted run.  Free space is simulated through
# OERCEL_TEST_DISK_FREE_FILE (a file holding the number of free bytes).
# usage: pc/tests/test_disk_guard.sh [outdir]     (default pc/_test/disk; ~1-2 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/disk}
RUNS=$OUT/runs
rm -rf "$OUT"; mkdir -p "$RUNS"
export OERCEL_NO_BUILD=1
export OERCEL_TEST_DISK_FREE_FILE=$(pwd)/$OUT/free_bytes
export OERCEL_TEST_HOST_FREE_FILE=$OERCEL_TEST_DISK_FREE_FILE   # in WSL2 also the Windows drive C: (same simulated value)
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
INI=engine/params/soup_small.ini
OV="L=40 steps=60000 snap_every=1000 ckpt_every=1000 log_every=10000"
RD=$RUNS/d1
st() { python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['status'])"; }
step() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.current_step('$RD'))"; }
engine/oercel $INI $OUT/ref $OV threads=1 >/dev/null
echo 100000000000 > $OERCEL_TEST_DISK_FREE_FILE          # 100 GB free
python3 pc/longrun.py d1 --ini $INI --set $OV --engine cpu --threads 1 --chunk-min 1 --analyse-uur 0 --geen-beelden \
  --analyse-jobs 1 --poll 0.5 --min-vrij-gb 10 --runs-dir $RUNS --achtergrond >/dev/null
t=0; while [ "$(step)" -lt 8000 ] && [ $t -lt 120 ]; do sleep 0.5; t=$((t + 1)); done
echo 5000000000 > $OERCEL_TEST_DISK_FREE_FILE            # 5 GB free: below the 10 GB limit
t=0; while [ "$(st)" != wacht_op_schijf ] && [ $t -lt 180 ]; do sleep 0.5; t=$((t + 1)); done
[ "$(st)" = wacht_op_schijf ] && pass "supervisor paused the run at step $(step)" || fail "no pause (status $(st))"
grep -q "stopping at step .* (signal)" $RD/log.txt && pass "engine stopped with a checkpoint" || fail "engine did not stop cleanly"
grep -q "GEPAUZEERD" $RD/STATUS.md && pass "STATUS.md says GEPAUZEERD" || fail "STATUS.md"
s1=$(step); sleep 5; s2=$(step)
[ "$s1" = "$s2" ] && pass "no progress while paused ($s1)" || fail "progress while paused ($s1 -> $s2)"
echo 100000000000 > $OERCEL_TEST_DISK_FREE_FILE          # space is back
t=0; while [ "$(st)" != klaar ] && [ $t -lt 400 ]; do sleep 0.5; t=$((t + 1)); done
[ "$(st)" = klaar ] && pass "continued by itself and finished" || fail "status $(st)"
ok=1; for f in stats.csv ckpt.bin snap_0000060000.bin; do cmp -s $OUT/ref/$f $RD/$f || { ok=0; echo "  differs: $f"; }; done
[ $ok = 1 ] && pass "result bitwise identical to the uninterrupted run" || fail "result differs"
echo "== summary: $fails failed check(s) =="
exit $fails
