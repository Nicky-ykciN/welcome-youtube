#!/bin/bash
# Soup comparison (membrane physics of notes/membranen/teamA_membranes.ini at L=64):
# reference CPU engine vs oercel_gpu (or oercel_emu), two seeds, then tools/analyze.py.
# usage: tests/run_soup_compare.sh ENGINE_BIN OUTPREFIX [steps] [threads] [seeds...]
set -u
cd "$(dirname "$0")/.."            # -> engine_gpu/
BIN=$1; OUT=$2; STEPS=${3:-60000}; TH=${4:-1}; shift 4 2>/dev/null || shift $#
SEEDS=${*:-"1 2"}
INI=../notes/membranen/teamA_membranes.ini
[ -f "$INI" ] || INI=tests/teamA_membranes.ini
for sd in $SEEDS; do
  $BIN $INI ${OUT}_s$sd L=64 seed=$sd steps=$STEPS snap_every=2000 stats_every=500 ckpt_every=20000 log_every=10000 threads=$TH > ${OUT}_s$sd.out 2>&1 &
done
wait
