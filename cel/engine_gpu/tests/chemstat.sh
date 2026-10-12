#!/bin/bash
# Focused chemistry statistics: well-mixed water with catalysts and nutrients (no structure), all
# reactions on, both engines; compares reaction rates per catalyst-check, decay and feed totals,
# and the mutation fraction (expected mu).
# Two runs per engine: "syn" (synthesis only, constant catalyst number) and "rep" (replication +
# mutation + catalyst decay roughly balanced, no synthesis).
# usage: tests/chemstat.sh ENGINE REF OUTPREFIX [steps] [threads] [extra key=value ...]
set -u
cd "$(dirname "$0")/.."
ENG=$1; REF=$2; OUT=$3; ST=${4:-20000}; TH=${5:-1}; shift 5 2>/dev/null || shift $#
INI=../engine/params/water.ini; [ -f "$INI" ] || INI=tests/water.ini
BASE="L=48 f_lip=0 f_Ka=0.02 f_Kb=0.01 c_N=0.12 chem=1 n_chem=10 p_nd=0.001 feed=uniform p_feed=0.01 feed_cap=0.12"
BASE="$BASE steps=$ST snap_every=0 stats_every=100 log_every=0 ckpt_every=0"
f=0
for mode in syn rep; do
  if [ $mode = syn ]; then CO="$BASE p_syn_a=0.02 p_syn_b=0.06 p_rep_a=0 p_rep_b=0 p_kd=0 p_ld=0.02 $*"
  else CO="$BASE p_syn_a=0 p_syn_b=0 p_rep_a=0.005 p_rep_b=0.005 mu=0.3 p_kd=0.0025 p_ld=0 $*"; fi
  $REF $INI ${OUT}_${mode}_ref $CO seed=11 threads=$TH > /dev/null & bg=$!
  $ENG $INI ${OUT}_${mode}_gpu $CO seed=11 threads=$TH > /dev/null
  wait $bg
  echo "-- $mode"
  python3 tests/compare.py chem ${OUT}_${mode}_ref ${OUT}_${mode}_gpu; f=$((f + $?))
done
python3 - ${OUT}_rep_ref ${OUT}_rep_gpu << 'PY'
import sys, numpy as np
bad = 0
for run in sys.argv[1:]:
    k = [l.split(',')[1] for l in open(run + '/events.csv').readlines()[1:]]
    rep, mut = k.count('rep'), k.count('mut')
    fr = mut / max(rep + mut, 1); se = np.sqrt(0.3 * 0.7 / max(rep + mut, 1))
    ok = abs(fr - 0.3) < 4 * se
    bad += not ok
    print(('PASS' if ok else 'FAIL') + f'  mutation fraction {run.split("/")[-1]}: mut/(rep+mut) = {fr:.3f} +- {se:.3f} (mu = 0.3), {rep + mut} replications')
sys.exit(bad)
PY
exit $(( f + $? ))
