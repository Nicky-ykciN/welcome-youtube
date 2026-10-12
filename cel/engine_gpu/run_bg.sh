#!/bin/bash
# Start or continue an oercel_gpu run in the background (it keeps running when the terminal or
# the Claude session ends).
#
#   engine_gpu/run_bg.sh params.ini outdir [key=value ...]
#
# - If outdir/ckpt.bin exists, the run continues from it (restart=outdir/ckpt.bin); otherwise it
#   starts fresh.  `steps` is the absolute end step, as with the CPU engine.
# - Console output goes to outdir/console.txt, the process id to outdir/engine.pid.
# - Progress:  tail -f outdir/log.txt
# - Stop cleanly (finishes the step, writes ckpt.bin):  kill $(cat outdir/engine.pid)
# - ENGINE=/path/to/binary overrides the engine (default: oercel_gpu next to this script).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE=${ENGINE:-$HERE/oercel_gpu}
[ $# -ge 2 ] || { sed -n '2,13p' "$0"; exit 2; }
INI=$1; OUTD=$2; shift 2
[ -x "$ENGINE" ] || { echo "no engine at $ENGINE (run $HERE/setup_wsl.sh)"; exit 1; }
[ -f "$INI" ] || { echo "no parameter file $INI"; exit 1; }
mkdir -p "$OUTD"
if [ -f "$OUTD/engine.pid" ] && kill -0 "$(cat "$OUTD/engine.pid")" 2>/dev/null; then
  echo "already running in $OUTD (pid $(cat "$OUTD/engine.pid"))"; exit 1
fi
RS=""
[ -f "$OUTD/ckpt.bin" ] && RS="restart=$OUTD/ckpt.bin"
# setsid: own session/process group, so that signals to the starting shell's process group (e.g. when
# a terminal or a Claude session ends) do not reach the engine; the engine's PID stays $!
SETSID=$(command -v setsid || true)
nohup $SETSID "$ENGINE" "$INI" "$OUTD" "$@" $RS >> "$OUTD/console.txt" 2>&1 < /dev/null &
echo $! > "$OUTD/engine.pid"
echo "started pid $! in $OUTD ${RS:+(continuing from ckpt.bin)}; follow with: tail -f $OUTD/log.txt"
