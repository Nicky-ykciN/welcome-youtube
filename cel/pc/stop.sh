#!/usr/bin/env bash
# Oercel — alle experimenten netjes stoppen.  In een Ubuntu-terminal (WSL), vanuit de repo:
#
#     bash cel/pc/stop.sh            alle lange runs en sweeps stoppen; Claude Remote Control blijft draaien
#     bash cel/pc/stop.sh --alles    ook Claude Remote Control stoppen (tmux-sessie 'oercel-claude')
#
# Elke engine schrijft eerst een checkpoint (dat duurt hooguit een paar minuten).  Er gaat niets
# verloren: bash cel/pc/start.sh hervat later precies wat hier gestopt is, vanaf dat checkpoint.
set -u -o pipefail
PC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SES=${OERCEL_TMUX_SESSION:-oercel-claude}
TMUXC=(tmux)
[ -n "${OERCEL_TMUX_SOCKET:-}" ] && TMUXC=(tmux -L "$OERCEL_TMUX_SOCKET")
ALLES=0
for arg in "$@"; do
  case "$arg" in
    --alles) ALLES=1 ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "onbekende optie: $arg (alleen --alles)"; exit 2 ;;
  esac
done

echo "== Experimenten stoppen =="
python3 "$PC_DIR/plan.py" stop
rc=$?
echo
python3 "$PC_DIR/status.py" --kort || true
echo
if [ "$ALLES" = 1 ]; then
  if command -v tmux >/dev/null 2>&1 && "${TMUXC[@]}" has-session -t "=$SES" 2>/dev/null; then
    "${TMUXC[@]}" kill-session -t "=$SES" && echo "Claude Remote Control gestopt (tmux-sessie '$SES')."
  else
    echo "Claude Remote Control draaide niet (geen tmux-sessie '$SES')."
  fi
else
  echo "Claude Remote Control blijft draaien (ook stoppen: bash cel/pc/stop.sh --alles)."
fi
echo "Weer starten: bash cel/pc/start.sh  (hervat alles wat hier gestopt is)"
exit "$rc"
