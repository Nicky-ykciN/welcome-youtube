#!/bin/bash
# Large-box smoke test (memory, multi-level scan, snapshot IO at size): the step-0 snapshot of a
# soup at L must be bitwise identical to the reference engine's; then a few steps must run.
# usage: tests/bigbox_smoke.sh ENGINE REF OUTDIR [L] [steps] [threads]
set -u
cd "$(dirname "$0")/.."
ENG=$1; REF=$2; OUT=$3; L=${4:-1024}; ST=${5:-20}; TH=${6:-1}
INI=../engine/params/soup_small.ini; [ -f "$INI" ] || INI=tests/soup_small.ini
rm -rf "$OUT"; mkdir -p "$OUT"
$REF $INI "$OUT/ref" L=$L steps=0 snap_every=10 stats_every=10 log_every=0 ckpt_every=0 threads=$TH > /dev/null 2>&1
t0=$(date +%s)
$ENG $INI "$OUT/gpu" L=$L steps=$ST snap_every=10 stats_every=10 log_every=10 ckpt_every=0 threads=$TH 2>&1 | grep -E "ms/step|N=|error|rounds"
echo "wall time $(( $(date +%s) - t0 )) s"
if cmp -s "$OUT/ref/snap_0000000000.bin" "$OUT/gpu/snap_0000000000.bin"; then echo "PASS  L=$L step-0 snapshot bitwise identical to the reference"; else echo "FAIL  L=$L step-0 snapshot differs"; fi
python3 ../engine/tests/snapcheck.py snap "$OUT/gpu/snap_$(printf %010d $ST).bin" | head -4
tail -n 2 "$OUT/gpu/stats.csv"
rm -f "$OUT"/*/snap_*.bin "$OUT"/*/ckpt.bin
