#!/bin/bash
# Run every pc/ test in turn (CPU engine, 1-2 threads, small boxes; ~25-35 minutes in total).
# Results: pc/_test/<test>.txt; prints PASS/FAIL lines and a summary.  Exit code = failed tests.
#   ENGINE_EMU=path   additionally run the kill test with that engine (e.g. engine_gpu/oercel_emu or
#                     engine_gpu/oercel_gpu on the GPU machine)
cd "$(dirname "$0")/../.." || exit 1     # -> cel/
mkdir -p pc/_test
bad=0
for t in test_longrun_kill test_longrun_extra test_thinning test_sweep_kill test_reboot test_disk_guard \
         test_gpu_fallback test_stop_hervat test_kill_stress; do
  echo "######## $t $(date +%T)"
  if timeout 1200 bash pc/tests/$t.sh > pc/_test/$t.txt 2>&1; then echo "OK"; else echo "FOUT (zie pc/_test/$t.txt)"; bad=$((bad + 1)); fi
  grep -E "^(PASS|FAIL)" pc/_test/$t.txt | cut -c1-160
done
if [ -n "${ENGINE_EMU:-}" ]; then
  echo "######## test_longrun_kill met ENGINE=$ENGINE_EMU $(date +%T)"
  if ENGINE=$ENGINE_EMU OV="L=32 steps=24000 snap_every=1000 ckpt_every=2000 stats_every=100 log_every=4000" KILL_STEPS="5000 11000 17000" \
     timeout 1200 bash pc/tests/test_longrun_kill.sh pc/_test/kill_engine > pc/_test/test_kill_engine.txt 2>&1; then echo OK
  else echo "FOUT (zie pc/_test/test_kill_engine.txt)"; bad=$((bad + 1)); fi
  grep -E "^(PASS|FAIL)" pc/_test/test_kill_engine.txt
fi
echo "######## setup_wsl.sh --test-functies"
bash pc/setup_wsl.sh --test-functies | tail -1 | grep -q "== 0 fout" && echo OK || { echo FOUT; bad=$((bad + 1)); }
echo "== $bad test(s) mislukt =="
exit $bad
