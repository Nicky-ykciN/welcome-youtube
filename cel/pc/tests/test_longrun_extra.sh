#!/bin/bash
# More pc/longrun.py checks (small CPU runs, 1 thread):
#   1. engine choice 'auto' takes the GPU engine when nvidia-smi works and engine_gpu/oercel_gpu exists
#      (simulated: a fake nvidia-smi and a stand-in "GPU engine" that is the CPU engine, so the
#      supervisor's GPU code path runs here; the real CUDA engine is NOT tested by this)
#   2. --stop: clean stop with checkpoint, state 'gestopt', status.py lists the resume command
#   3. a corrupt checkpoint (ckpt.bin and its hard-linked copy truncated) -> the supervisor falls back to
#      an older kept checkpoint and the run still ends bitwise identical to an uninterrupted run
#   4. an unknown parameter is refused before anything starts
#   5. --van-ckpt: a new run continuing from another run's checkpoint equals a direct engine restart
# usage: pc/tests/test_longrun_extra.sh [outdir]     (default pc/_test/extra; ~2 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/extra}
RUNS=$OUT/runs
rm -rf "$OUT"; mkdir -p "$RUNS" "$OUT/fakebin"
export OERCEL_NO_BUILD=1
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
cat > "$OUT/fakebin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in
  *--query-gpu=name,memory.total,memory.used*) echo "Quadro RTX 8000 (NEP), 49152, 900, 97, 60";;
  *--query-compute-apps*) ;;
  *) echo "| NVIDIA-SMI 565.77.01   Driver Version: 566.14   CUDA Version: 12.7 |";;
esac
EOF
printf '#!/bin/bash\nexec %s "$@"\n' "$(pwd)/engine/oercel" > "$OUT/fakebin/oercel_gpu"
chmod +x "$OUT/fakebin/nvidia-smi" "$OUT/fakebin/oercel_gpu"
export PATH="$(pwd)/$OUT/fakebin:$PATH"
export OERCEL_ENGINE_GPU="$(pwd)/$OUT/fakebin/oercel_gpu"
export OERCEL_GPU_SMOKE_FILE="$(pwd)/$OUT/gpu_smoke.json" OERCEL_GPU_SELFTEST_FILE="$(pwd)/$OUT/gpu_selftest.json"   # not pc/_build
INI=engine/params/soup_small.ini
OV="L=40 steps=30000 snap_every=1000 ckpt_every=2000 stats_every=100 log_every=5000"
RD=$RUNS/g1
st() { python3 -c "import json; print(json.load(open('$RD/pc_longrun.json'))['$1'])"; }
step() { python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.current_step('$RD'))"; }

engine/oercel $INI $OUT/ref $OV threads=1 >/dev/null

echo "== 1. auto engine with a (simulated) GPU =="
python3 pc/longrun.py g1 --ini $INI --set $OV --threads 1 --chunk-min 0.1 --analyse-uur 0 --analyse-jobs 1 --width 600 \
  --poll 0.5 --backoff 1 --runs-dir $RUNS --beelden-dir $OUT/beelden --achtergrond > $OUT/start.txt
[ "$(st engine)" = gpu ] && pass "auto chose the GPU engine ($(st engine_path))" || fail "engine = $(st engine)"
t=0; while [ "$(step)" -lt 12000 ] && [ $t -lt 240 ]; do sleep 0.5; t=$((t + 1)); done
grep -q "GPU-engine (Quadro RTX 8000 (NEP)" $RD/STATUS.md && pass "STATUS.md shows the GPU line" || fail "STATUS.md without GPU info"

echo "== 2. --stop =="
python3 pc/longrun.py g1 --stop --runs-dir $RUNS
[ "$(st status)" = gestopt ] && pass "state 'gestopt' at step $(step)" || fail "state $(st status)"
grep -q "stopping at step .* (signal)" $RD/log.txt && pass "engine stopped cleanly with a checkpoint" || fail "no clean engine stop"
python3 pc/status.py --runs-dir $RUNS > $OUT/status.txt
grep -q "pc/longrun.py g1 --achtergrond --runs-dir" $OUT/status.txt && pass "status.py lists the resume command" || { fail "status.py"; cat $OUT/status.txt; }

echo "== 3. corrupt checkpoint -> fallback to an older copy =="
S=$(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.ckpt_step('$RD/ckpt.bin'))")
ls $RD/ckpt_*.bin | sed 's/^/   kept: /'
truncate -s 5000 $RD/ckpt.bin      # also truncates the hard-linked ckpt_<S>.bin (same file)
python3 pc/longrun.py g1 --runs-dir $RUNS --achtergrond > /dev/null
t=0; while [ "$(st status)" != klaar ] && [ $t -lt 400 ]; do sleep 0.5; t=$((t + 1)); [ "$(st status)" = fout ] && break; done
[ "$(st status)" = klaar ] && pass "run finished after the corrupt checkpoint at step $S" || fail "status $(st status)"
grep -E "lijkt onbruikbaar|ENGINE GESTOPT" $RD/pc_supervisor.log | sed 's/^/   /' | cut -c1-150
grep -q "herstart van ckpt_" $RD/pc_supervisor.log && pass "restarted from an older kept copy: $(grep -o 'herstart van ckpt_[0-9]*.bin' $RD/pc_supervisor.log | tail -1)" || fail "no fallback restart"
ok=1; for f in stats.csv ckpt.bin snap_0000030000.bin snap_0000020000.bin; do cmp -s $OUT/ref/$f $RD/$f || { ok=0; echo "   differs: $f"; }; done
cmp -s <(tail -n +2 $OUT/ref/events.csv) <(tail -n +2 $RD/events.csv) || { ok=0; echo "   differs: events.csv"; }
[ $ok = 1 ] && pass "final outputs bitwise identical to the uninterrupted run" || fail "outputs differ"

echo "== 4. unknown parameter =="
if python3 pc/longrun.py bad --ini $INI --set foo_bar=1 --engine cpu --runs-dir $RUNS > $OUT/bad.txt 2>&1; then
  fail "unknown key accepted"
else
  grep -q foo_bar $OUT/bad.txt && pass "refused: $(head -1 $OUT/bad.txt | cut -c1-110)" || fail "wrong message: $(cat $OUT/bad.txt)"
fi
[ ! -d $RUNS/bad ] && pass "nothing was created for the refused run" || fail "run dir created"

echo "== 5. --van-ckpt (branch a new run from another run's checkpoint) =="
OV2="L=40 steps=35000 snap_every=1000 ckpt_every=2000 stats_every=100 log_every=5000"
engine/oercel $INI $OUT/ref2 $OV2 threads=1 restart=$OUT/ref/ckpt.bin >/dev/null
python3 pc/longrun.py g2 --ini $INI --set $OV2 --engine cpu --threads 1 --van-ckpt $RD/ckpt.bin --analyse-uur 0 --geen-beelden \
  --analyse-jobs 1 --poll 0.5 --runs-dir $RUNS > $OUT/g2.txt 2>&1
ok=1; for f in snap_0000035000.bin ckpt.bin; do cmp -s $OUT/ref2/$f $RUNS/g2/$f || { ok=0; echo "   differs: $f"; }; done
[ $ok = 1 ] && pass "run g2 from g1's checkpoint (30000 -> 35000) equals a direct engine restart" || fail "g2 differs"
echo "== 6. --van-ckpt with restart_reseed=1: branch once, then exact chunks =="
OV3="L=40 steps=40000 snap_every=1000 ckpt_every=1000 stats_every=100 log_every=5000"
engine/oercel $INI $OUT/ref3 $OV3 seed=7 threads=1 restart=$OUT/ref/ckpt.bin restart_reseed=1 >/dev/null
python3 pc/longrun.py g3 --ini $INI --set $OV3 seed=7 restart_reseed=1 --engine cpu --threads 1 --van-ckpt $RD/ckpt.bin \
  --chunk-min 0.03 --analyse-uur 0 --geen-beelden --analyse-jobs 1 --poll 0.5 --runs-dir $RUNS > $OUT/g3.txt 2>&1
nr=$(grep -c "reseeded" $RUNS/g3/log.txt); nc=$(grep -c "restart from" $RUNS/g3/log.txt)
[ "$nr" = 1 ] && [ "$nc" -ge 2 ] && pass "reseeded once, $nc restarts in total" || fail "reseeded $nr times in $nc restarts"
ok=1; for f in stats.csv snap_0000040000.bin ckpt.bin; do cmp -s $OUT/ref3/$f $RUNS/g3/$f || { ok=0; echo "   differs: $f"; }; done
[ $ok = 1 ] && pass "branched chunked run equals one direct branched engine run" || fail "g3 differs from ref3"
cmp -s $OUT/ref3/snap_0000035000.bin $OUT/ref2/snap_0000035000.bin && fail "branch identical to the exact continuation (seed ignored?)" || pass "the branch differs from the exact continuation (new random future)"
echo "== summary: $fails failed check(s) =="
exit $fails
