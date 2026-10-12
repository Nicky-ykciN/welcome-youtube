#!/bin/bash
# GPU engine present but NOT usable -> longrun.py falls back to the CPU engine; a GPU that disappears
# during a run does not get valid checkpoints marked as bad.  Simulated with a fake nvidia-smi and
# stand-in "GPU engines" (scripts), so it runs on any machine; the real CUDA engine is not used.
#   1. auto + a GPU binary that fails ("no CUDA device")       -> CPU engine, run finishes
#   2. --engine gpu with that binary                          -> refused with the reason, nothing created
#   3. auto + a working GPU binary whose setup self-test FAILED (pc/_build/gpu_selftest.json) -> CPU
#   4. auto + a working GPU binary                             -> GPU (smoke run passes, result cached)
#   5. the GPU disappears mid-run: the supervisor retries, marks NO checkpoint bad, ends 'fout' with a
#      hint; when the GPU is back, the same command resumes from the newest checkpoint and the result
#      is bitwise identical to an uninterrupted run
# usage: pc/tests/test_gpu_fallback.sh [outdir]     (default pc/_test/gpufb; ~2 minutes)
set -u
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
OUT=${1:-pc/_test/gpufb}
RUNS=$OUT/runs
rm -rf "$OUT"; mkdir -p "$RUNS" "$OUT/fakebin"
OUT=$(cd "$OUT" && pwd); RUNS=$OUT/runs
export OERCEL_NO_BUILD=1
export OERCEL_GPU_SELFTEST_FILE=$OUT/gpu_selftest.json OERCEL_GPU_SMOKE_FILE=$OUT/gpu_smoke.json
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
# a GPU engine that cannot find a device (like oercel_gpu on a machine whose driver is broken)
printf '#!/bin/bash\necho "oercel_gpu: error: no CUDA device available (no CUDA-capable device is detected)." >&2\nexit 1\n' > "$OUT/fakebin/gpu_kapot"
# a working stand-in GPU engine (the CPU engine), that fails while the file gpu_weg exists
printf '#!/bin/bash\n# werkende nep-GPU-engine\nif [ -f %s/gpu_weg ]; then echo "oercel_gpu: error: no CUDA device available (no CUDA-capable device is detected)." >&2; exit 1; fi\nexec %s "$@"\n' \
  "$OUT" "$(pwd)/engine/oercel" > "$OUT/fakebin/gpu_ok"
chmod +x "$OUT/fakebin/"*
export PATH="$OUT/fakebin:$PATH"
INI=engine/params/soup_small.ini
st() { python3 -c "import json; print(json.load(open('$RUNS/$1/pc_longrun.json')).get('$2'))"; }
COMMON="--threads 1 --analyse-uur 0 --geen-beelden --analyse-jobs 1 --poll 0.3 --backoff 0.2 --runs-dir $RUNS"

echo "== 1. auto with a GPU binary that does not run =="
OERCEL_ENGINE_GPU=$OUT/fakebin/gpu_kapot python3 pc/longrun.py f1 --ini $INI --set L=32 steps=3000 snap_every=1000 $COMMON > $OUT/f1.txt 2>&1
[ "$(st f1 engine)" = cpu ] && [ "$(st f1 status)" = klaar ] && pass "auto fell back to the CPU engine and finished" || { fail "engine $(st f1 engine), status $(st f1 status)"; tail -5 $OUT/f1.txt; }
grep -q "GPU-engine niet bruikbaar" $OUT/f1.txt && pass "reason printed: $(grep -o 'GPU-engine niet bruikbaar.*' $OUT/f1.txt | head -1 | cut -c1-110)" || fail "no reason printed"

echo "== 2. --engine gpu with that binary =="
if OERCEL_ENGINE_GPU=$OUT/fakebin/gpu_kapot python3 pc/longrun.py f2 --ini $INI --engine gpu $COMMON > $OUT/f2.txt 2>&1; then
  fail "a GPU engine that does not run was accepted"
else
  grep -q "no CUDA device" $OUT/f2.txt && pass "refused: $(head -1 $OUT/f2.txt | cut -c1-120)" || fail "wrong message: $(cat $OUT/f2.txt)"
fi
[ ! -d $RUNS/f2 ] && pass "nothing created for the refused run" || fail "run dir f2 created"

echo "== 3. working GPU binary, but the setup self-test FAILED for exactly this binary =="
sha=$(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.file_sha1('$OUT/fakebin/gpu_ok'))")
echo "{\"ok\": false, \"sha1\": \"$sha\", \"time\": \"test\", \"log\": \"runs/_setup/selftest_gpu.log\"}" > $OERCEL_GPU_SELFTEST_FILE
OERCEL_ENGINE_GPU=$OUT/fakebin/gpu_ok python3 pc/longrun.py f3 --ini $INI --set L=32 steps=3000 snap_every=1000 $COMMON > $OUT/f3.txt 2>&1
[ "$(st f3 engine)" = cpu ] && grep -q "zelftest van setup_wsl.sh faalde" $OUT/f3.txt && pass "failed self-test -> CPU engine" || fail "engine $(st f3 engine)"

echo "== 4. working GPU binary, self-test of ANOTHER build failed -> GPU =="
echo '{"ok": false, "sha1": "0000000000000000", "time": "test"}' > $OERCEL_GPU_SELFTEST_FILE
OERCEL_ENGINE_GPU=$OUT/fakebin/gpu_ok python3 pc/longrun.py f4 --ini $INI --set L=32 steps=3000 snap_every=1000 $COMMON > $OUT/f4.txt 2>&1
[ "$(st f4 engine)" = gpu ] && [ "$(st f4 status)" = klaar ] && pass "GPU engine chosen and run finished" || fail "engine $(st f4 engine) status $(st f4 status)"
python3 -c "import json; d=json.load(open('$OERCEL_GPU_SMOKE_FILE')); assert d['$sha']['ok']" && pass "smoke result cached per binary checksum" || fail "smoke cache"

echo "== 5. the GPU disappears during a run, and comes back =="
OV="L=32 steps=200000 snap_every=10000 ckpt_every=1000 stats_every=100 log_every=50000"
engine/oercel $INI $OUT/ref5 $OV threads=1 > /dev/null
export OERCEL_ENGINE_GPU=$OUT/fakebin/gpu_ok
python3 pc/longrun.py f5 --ini $INI --set $OV --chunk-min 0.05 $COMMON --achtergrond > /dev/null
t=0; while [ "$(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.durable_step('$RUNS/f5'))")" -lt 20000 ] && [ $t -lt 240 ]; do sleep 0.5; t=$((t + 1)); done
touch $OUT/gpu_weg
echo "  GPU gone at step $(python3 -c "import sys; sys.path.insert(0,'pc'); import pclib as P; print(P.durable_step('$RUNS/f5'))")"
t=0; while [ "$(st f5 status)" != fout ] && [ $t -lt 240 ]; do sleep 0.5; t=$((t + 1)); done
[ "$(st f5 status)" = fout ] && pass "supervisor gave up after repeated failures (status fout)" || fail "status $(st f5 status)"
[ "$(st f5 bad_ckpts)" = None ] && pass "no checkpoint marked bad (the failure was the GPU, not the file)" || fail "checkpoints marked bad: $(st f5 bad_ckpts)"
grep -q "GPU-engine start niet" $RUNS/f5/pc_supervisor.log && pass "hint about nvidia-smi / --engine cpu --forceer-engine logged" || fail "no GPU hint"
python3 pc/status.py --runs-dir $RUNS > $OUT/status5.txt
grep -q "f5 .*FOUT" $OUT/status5.txt && grep -q "pc/longrun.py f5 --achtergrond" $OUT/status5.txt && pass "status.py: FOUT + resume command" || { fail "status.py"; cat $OUT/status5.txt; }
rm -f $OUT/gpu_weg
python3 pc/longrun.py f5 --runs-dir $RUNS --achtergrond > /dev/null
t=0; while [ "$(st f5 status)" != klaar ] && [ $t -lt 400 ]; do sleep 0.5; t=$((t + 1)); done
[ "$(st f5 status)" = klaar ] && pass "resumed after the GPU came back and finished" || fail "status $(st f5 status)"
grep "herstart van" $RUNS/f5/pc_supervisor.log | tail -1 | grep -q "herstart van ckpt.bin" && pass "resumed from the newest checkpoint (ckpt.bin)" || fail "resumed from: $(grep 'herstart van' $RUNS/f5/pc_supervisor.log | tail -1)"
ok=1; for f in stats.csv ckpt.bin snap_0000200000.bin; do cmp -s $OUT/ref5/$f $RUNS/f5/$f || { ok=0; echo "  differs: $f"; }; done
[ $ok = 1 ] && pass "result bitwise identical to the uninterrupted run" || fail "result differs"
echo "== summary: $fails failed check(s) =="
exit $fails
