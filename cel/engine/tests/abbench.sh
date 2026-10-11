#!/bin/bash
# interleaved A/B benchmark: abbench.sh "label1|overrides1" "label2|overrides2" ... ; env REPS, STEPS, INI
REPS=${REPS:-3}; STEPS=${STEPS:-600}
INI=${INI:-$(dirname $0)/../params/soup_small.ini}
ENG=$(dirname $0)/../oercel
declare -A best
for r in $(seq $REPS); do
  for cfg in "$@"; do
    lab=${cfg%%|*}; ov=${cfg#*|}
    out=$($ENG $INI /tmp/oercel_ab_$$ steps=$STEPS snap_every=0 stats_every=0 ckpt_every=0 log_every=0 $ov | grep timing)
    ms=$(echo "$out" | sed 's/.*steps, \([0-9.]*\) ms.*/\1/')
    rest=$(echo "$out" | sed 's/.*ms\/step //')
    if [ -z "${best[$lab]}" ] || (( $(echo "$ms < ${best[$lab]%% *}" | bc -l) )); then best[$lab]="$ms $rest"; fi
    rm -rf /tmp/oercel_ab_$$
  done
done
for cfg in "$@"; do lab=${cfg%%|*}; echo "$lab: ${best[$lab]}"; done
