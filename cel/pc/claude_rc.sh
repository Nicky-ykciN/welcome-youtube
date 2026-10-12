#!/usr/bin/env bash
# Oercel: Claude Remote Control, zoals start.sh het start in de tmux-sessie 'oercel-claude'.
#
# Draait `claude remote-control --name "Oercel werkstation"` in de repo-map en start het vanzelf
# opnieuw als het stopt (de server stopt bijvoorbeeld na ~10 minuten zonder netwerk); bij een herstart
# met --continue, zodat het gesprek verdergaat.  Stopt na 5 snelle mislukkingen achter elkaar (dan
# blijft de melding in beeld staan).  Ctrl+C stopt Claude en deze lus.
# Log: cel/pc/_build/claude_rc.log.   Stoppen van buitenaf: bash cel/pc/stop.sh --alles
set -u
# start.sh passes its environment through a file (HOME, PATH, CLAUDE_BIN, OERCEL_*)
if [ -n "${1:-}" ] && [ -r "$1" ]; then . "$1"; fi
PC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CEL=$(dirname "$PC_DIR")
REPO=$(dirname "$CEL")
STATE=${OERCEL_START_STATE:-$PC_DIR/_build}
mkdir -p "$STATE" 2>/dev/null
LOG=$STATE/claude_rc.log
NAME=${OERCEL_CLAUDE_NAME:-Oercel werkstation}
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
CLAUDE_BIN=${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}
# Remote Control werkt met het inloggen van je abonnement, niet met een API-sleutel
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
cd "$REPO" || { echo "map $REPO niet gevonden"; exec bash; }

cont=${OERCEL_CLAUDE_CONTINUE:-0}    # 1 = het vorige gesprek in deze map hervatten
quick=0
while :; do
  args=(remote-control --name "$NAME")
  [ "$cont" = 1 ] && args+=(--continue)
  printf '[%s] start: claude %s\n' "$(date '+%F %T')" "${args[*]}" >> "$LOG"
  t0=$(date +%s)
  "$CLAUDE_BIN" "${args[@]}"
  rc=$?
  dt=$(( $(date +%s) - t0 ))
  printf '[%s] claude stopte met code %s na %s s\n' "$(date '+%F %T')" "$rc" "$dt" >> "$LOG"
  if [ "$dt" -lt 60 ]; then
    quick=$((quick + 1))
    cont=0            # lukte het niet met --continue, dan de volgende keer zonder
  else
    quick=0
    cont=1            # na een echte sessie: bij herstart het gesprek hervatten
  fi
  if [ "$quick" -ge 5 ]; then
    echo
    echo "Claude Remote Control stopte 5 keer snel achter elkaar (laatste code $rc); ik probeer het niet meer."
    echo "Mogelijke oorzaken: niet ingelogd (typ: claude auth login), geen internet, of een abonnement"
    echo "zonder Remote Control.  Log: $LOG"
    echo "Opnieuw proberen: bash cel/pc/start.sh   (dit venster sluiten: exit)"
    printf '[%s] gestopt na 5 snelle mislukkingen\n' "$(date '+%F %T')" >> "$LOG"
    exec bash -i
  fi
  echo
  echo "Claude Remote Control is gestopt (code $rc). Over ${OERCEL_RC_RESTART_S:-30} seconden start ik hem opnieuw (Ctrl+C = niet doen)."
  sleep "${OERCEL_RC_RESTART_S:-30}"
done
