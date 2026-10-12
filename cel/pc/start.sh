#!/usr/bin/env bash
# Oercel — alles starten met één commando.  In een Ubuntu-terminal (WSL), vanuit de repo:
#
#     bash cel/pc/start.sh
#
# Veilig om opnieuw te draaien, ook na een herstart van de pc: wat al gedaan is wordt overgeslagen.
#   1. installatie (cel/pc/setup_wsl.sh) als die nog nooit gelukt is — vraagt dan één keer je wachtwoord
#   2. Claude Code installeren (officiële installer, zonder sudo) als 'claude' ontbreekt
#   3. de experimenten uit cel/pc/plan.txt starten of hervatten, op de achtergrond
#   4. korte status
#   5. Claude Remote Control in tmux-sessie 'oercel-claude' (eerst inloggen als dat nog niet gedaan is);
#      daarna staat de sessie 'Oercel werkstation' in de Claude-app onder Code
# Opties:
#   --geen-setup     installatie overslaan        --setup          installatie opnieuw, ook als hij al gelukt is
#   --geen-claude    stap 2 en 5 overslaan        --alleen-plan    alleen stap 3 en 4 (handig voor Claude)
# Stoppen: bash cel/pc/stop.sh (experimenten; Claude blijft draaien)  ·  bash cel/pc/stop.sh --alles
set -u -o pipefail

PC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CEL=$(dirname "$PC_DIR")
REPO=$(dirname "$CEL")
# test hooks (only for cel/pc/tests/test_start.sh; never needed on the workstation)
SETUP_LOGDIR=${OERCEL_SETUP_LOGDIR:-$CEL/runs/_setup}
STATE=${OERCEL_START_STATE:-$PC_DIR/_build}
SES=${OERCEL_TMUX_SESSION:-oercel-claude}
CLAUDE_URL=${OERCEL_CLAUDE_INSTALL_URL:-https://claude.ai/install.sh}
RC_NAME=${OERCEL_CLAUDE_NAME:-Oercel werkstation}
TMUXC=(tmux)
[ -n "${OERCEL_TMUX_SOCKET:-}" ] && TMUXC=(tmux -L "$OERCEL_TMUX_SOCKET")

DO_SETUP=auto; DO_CLAUDE=1; DO_PLAN=1
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
for arg in "$@"; do
  case "$arg" in
    --geen-setup) DO_SETUP=0 ;;
    --setup) DO_SETUP=1 ;;
    --geen-claude) DO_CLAUDE=0 ;;
    --alleen-plan) DO_SETUP=0; DO_CLAUDE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "onbekende optie: $arg"; usage; exit 2 ;;
  esac
done

# ------------------------------------------------------------------------------------ helpers
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
say() { printf '%s\n' "$*"; }
kop() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
goed() { printf '  %sOK%s  %s\n' "$G" "$N" "$*"; }
let_op() { printf '  %sLET OP%s  %s\n' "$Y" "$N" "$*"; }
fout() { printf '  %sFOUT%s  %s\n' "$R" "$N" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
interactive() { [ -t 0 ] && [ -t 1 ]; }
tm() { "${TMUXC[@]}" "$@" 9>&-; }
RESULT=()     # one line per step for the summary at the end
noteer() { RESULT+=("$(printf '%-22s %s' "$1" "$2")"); }

# ------------------------------------------------------------------------------------ 0. controles
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
  say "Start dit script zonder sudo:   bash cel/pc/start.sh"
  say "(het vraagt zelf één keer om je wachtwoord als dat nodig is)"
  exit 1
fi

# the repository on the Windows drive (/mnt/c/...): ~10x slower and file locking may not work.
# Make a copy in the Linux home directory and continue there.
case "$REPO/" in
  /mnt/[a-zA-Z]/*|"${OERCEL_TEST_WINDRIVE:-/nonexistent-oercel}"/*)
    dest=$HOME/$(basename "$REPO")
    say "De repo staat op de Windows-schijf ($REPO). Daar is alles ~10x trager."
    if [ -f "$dest/cel/pc/start.sh" ]; then
      say "In je Linux-thuismap staat al een kopie: $dest — ik ga daar verder."
    elif [ -e "$dest" ]; then
      say "Ik wilde een kopie maken in $dest, maar die map bestaat al (en is geen Oercel-repo)."
      say "Hernoem die map, of kloon de repo zelf:  git clone https://github.com/Nicky-ykciN/welcome-youtube ~/welcome-youtube"
      exit 1
    else
      if ! have git; then say "git ontbreekt: sudo apt-get install -y git, en start dit script opnieuw."; exit 1; fi
      say "Ik maak een kopie in je Linux-thuismap: $dest"
      url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
      br=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      git clone -q "$REPO" "$dest" || { say "kopiëren mislukt"; exit 1; }
      [ -n "$url" ] && git -C "$dest" remote set-url origin "$url"
      [ -n "$br" ] && [ "$br" != HEAD ] && git -C "$dest" checkout -q "$br" 2>/dev/null
    fi
    say "Gebruik voortaan:   cd $dest && bash cel/pc/start.sh"
    exec bash "$dest/cel/pc/start.sh" "$@"
    ;;
esac

mkdir -p "$STATE" || { say "kan $STATE niet maken"; exit 1; }
# only one start.sh at a time (a second window would start everything twice)
if have flock; then
  exec 9>"$STATE/start.lock"
  if ! flock -n 9; then
    say "start.sh draait al (in een ander venster). Kijk daar, of wacht tot het klaar is."
    exit 0
  fi
fi

say "${B}Oercel starten${N} — $(date '+%Y-%m-%d %H:%M')   (repo: $REPO)"
if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  say "(dit is geen WSL; ik ga door als gewone Linux)"
fi

# ------------------------------------------------------------------------------------ 1. installatie
# setup_wsl.sh writes runs/_setup/setup_<time>.log and ends it with "Klaar. Volgende stap" when nothing
# failed.  The newest log that is not a dry run tells whether the setup has succeeded.
setup_logs() {     # real (not dry-run) setup logs, newest first
  local f
  while IFS= read -r f; do
    [ -f "$f" ] && ! grep -qE '^(DROOG:|TESTMODUS)' "$f" && echo "$f"
  done < <(ls -t "$SETUP_LOGDIR"/setup_*.log 2>/dev/null)
}
setup_state() {
  local f
  f=$(setup_logs | head -n1)
  if [ -z "$f" ]; then echo nooit
  elif grep -q '^Klaar\. Volgende stap' "$f"; then echo ok
  else echo mislukt; fi
}
setup_fails_in_row() {
  local f n=0
  while IFS= read -r f; do
    grep -q '^Klaar\. Volgende stap' "$f" && break
    n=$((n + 1))
  done < <(setup_logs)
  echo "$n"
}
gpu_now_ok() {
  local smi
  smi=$(command -v nvidia-smi 2>/dev/null || true)
  [ -z "$smi" ] && [ -x /usr/lib/wsl/lib/nvidia-smi ] && smi=/usr/lib/wsl/lib/nvidia-smi
  [ -n "$smi" ] && "$smi" >/dev/null 2>&1
}
tools_python() { if [ -x "$PC_DIR/.venv/bin/python" ]; then echo "$PC_DIR/.venv/bin/python"; else echo python3; fi; }
essentials_ok() {
  [ -x "$CEL/engine/oercel" ] && "$CEL/engine/oercel" --params >/dev/null 2>&1 &&
    "$(tools_python)" -c 'import numpy, scipy, matplotlib, PIL' >/dev/null 2>&1
}
run_setup() {
  kop "1. Installatie (cel/pc/setup_wsl.sh)"
  if [ "$1" = nooit ]; then
    say "Eerste keer: dit duurt 20-50 minuten (CUDA-toolkit van enkele GB downloaden, engines bouwen, tests)."
    say "sudo vraagt zo één keer je Linux-wachtwoord (je ziet niets als je typt; daarna Enter)."
    say "Daarna mag je weglopen; aan het eind vraag ik je nog om bij Claude in te loggen."
  elif [ "$1" = ok ]; then
    say "Installatie opnieuw (--setup); wat al klaar is gaat snel."
  else
    say "Een eerdere installatie is niet helemaal gelukt; ik probeer het opnieuw (wat al klaar is gaat snel)."
  fi
  local rc
  if [ -n "${OERCEL_SETUP_CMD:-}" ]; then
    bash -c "$OERCEL_SETUP_CMD" 9>&-
  else
    bash "$PC_DIR/setup_wsl.sh" 9>&-
  fi
  rc=$?
  if [ "$rc" = 0 ]; then
    goed "installatie gelukt"; noteer "installatie" "gelukt"
    say "  (\"Volgende stap\" hierboven doet start.sh nu zelf: je hoeft niets te typen.)"
  else
    fout "de installatie meldde fouten (zie de SAMENVATTING hierboven; log in cel/runs/_setup/)."
    say "  Ik ga door met wat wel werkt. Claude kan het log lezen en helpen; start.sh probeert de"
    say "  installatie de volgende keer opnieuw."
    noteer "installatie" "FOUTEN (log: cel/runs/_setup/)"
  fi
  return "$rc"
}
run_plan() {
  kop "$1"
  python3 "$PC_DIR/plan.py" start 9>&-
  local rc=$?
  [ "$rc" = 0 ] && noteer "experimenten" "plan toegepast (cel/pc/plan.txt)" || noteer "experimenten" "plan toegepast, met meldingen (zie boven)"
  return 0
}

PLAN_DONE=0
SST=$(setup_state)
WANT_SETUP=0
if [ "$DO_SETUP" = 1 ]; then WANT_SETUP=1
elif [ "$DO_SETUP" = auto ]; then
  if [ "$SST" = nooit ] || ! essentials_ok; then WANT_SETUP=1
  elif [ "$SST" = mislukt ]; then
    NFAIL=$(setup_fails_in_row)
    if [ "$NFAIL" -lt 3 ]; then WANT_SETUP=1
    elif grep -q "nvidia-smi werkt niet" "$(setup_logs | head -n1)" && gpu_now_ok; then
      WANT_SETUP=1; say "De GPU werkt nu wel (nvidia-smi); de installatie wordt opnieuw geprobeerd."
    else
      kop "1. Installatie"
      let_op "de installatie is ${NFAIL}x achter elkaar mislukt; ik probeer het niet elke keer automatisch opnieuw."
      say "  Wat er mis is staat in cel/runs/_setup/ (Claude kan het lezen). Opnieuw proberen: bash cel/pc/start.sh --setup"
      noteer "installatie" "${NFAIL}x mislukt; opnieuw: start.sh --setup"
    fi
  fi
fi
if [ "$WANT_SETUP" = 1 ]; then
  # a failed earlier attempt must not keep running experiments waiting (e.g. after a reboot): resume first
  if [ "$SST" = mislukt ] && [ "$DO_PLAN" = 1 ] && essentials_ok; then
    run_plan "Experimenten hervatten (vóór de nieuwe installatiepoging)"
    PLAN_DONE=1
  fi
  run_setup "$SST"
elif [ "$DO_SETUP" = auto ] && [ "$SST" = ok ]; then
  goed "installatie: al eerder gelukt ($(setup_logs | head -n1 | xargs -r basename))"
  noteer "installatie" "al eerder gelukt"
fi

# packages start.sh itself needs (setup_wsl.sh installs them too; this is for an older setup)
apt_install() {
  local pk=("$@")
  if [ "${OERCEL_TEST_NO_APT:-0}" = 1 ]; then say "  [test] zou installeren: apt-get install ${pk[*]}"; return 1; fi
  local S=""
  [ "$(id -u)" -ne 0 ] && S=sudo
  if [ -n "$S" ] && ! sudo -n true 2>/dev/null && ! interactive; then
    say "  ${pk[*]} ontbreekt en installeren vraagt je wachtwoord: start dit script in een terminal."
    return 1
  fi
  say "  installeren: ${pk[*]} (sudo vraagt misschien je wachtwoord)"
  $S env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 -y -q install "${pk[@]}" 9>&- ||
    { $S apt-get -o DPkg::Lock::Timeout=600 -q update 9>&- && \
      $S env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 -y -q install "${pk[@]}" 9>&-; }
}

# ------------------------------------------------------------------------------------ 2. Claude Code
CLAUDE_BIN=""
find_claude() {
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  if [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ]; then CLAUDE_BIN=$HOME/.local/bin/claude; fi
  [ -n "$CLAUDE_BIN" ]
}
PATH_ADDED=0    # 1 = this terminal (the parent shell) does not have ~/.local/bin in PATH yet
fix_path() {
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH"; PATH_ADDED=1 ;; esac
  # new terminals: ~/.local/bin in PATH via ~/.bashrc (official advice when 'claude' is not found)
  if [ "$CLAUDE_BIN" = "$HOME/.local/bin/claude" ] && ! grep -qs '\.local/bin' "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'EOF'

# Oercel (cel/pc/start.sh): Claude Code staat in ~/.local/bin   # oercel-claude-path
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
EOF
    say "  ~/.bashrc: ~/.local/bin staat nu in PATH (voor nieuwe terminals)"
  fi
}
install_claude() {
  kop "2. Claude Code"
  if find_claude; then
    fix_path
    goed "Claude Code is er al: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -n1))"
    noteer "Claude Code" "$("$CLAUDE_BIN" --version 2>/dev/null | head -n1)"
    return 0
  fi
  have curl || apt_install curl || { fout "curl ontbreekt; Claude Code kan niet geïnstalleerd worden"; noteer "Claude Code" "FOUT: curl ontbreekt"; return 1; }
  say "  installeren met de officiële installer (zonder sudo): curl -fsSL $CLAUDE_URL | bash"
  if ! curl -fsSL "$CLAUDE_URL" | bash 9>&-; then
    fout "de installer gaf een fout (internet? zie hierboven)"
  fi
  if find_claude; then
    fix_path
    local v
    v=$("$CLAUDE_BIN" --version 2>/dev/null | head -n1)
    if [ -n "$v" ]; then goed "Claude Code geïnstalleerd: $CLAUDE_BIN ($v)"; noteer "Claude Code" "geïnstalleerd ($v)"
    else fout "$CLAUDE_BIN --version werkt niet (probeer: claude doctor)"; noteer "Claude Code" "FOUT: --version werkt niet"; return 1; fi
  else
    fout "na de installatie is 'claude' niet te vinden (verwacht: ~/.local/bin/claude)"
    noteer "Claude Code" "FOUT: niet geïnstalleerd"
    return 1
  fi
}

# ------------------------------------------------------------------------------------ 5. Remote Control
CRED=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
logged_in() { [ -s "$CRED" ]; }
login_claude() {
  if logged_in; then goed "ingelogd bij Claude"; return 0; fi
  if ! interactive; then
    let_op "nog niet ingelogd bij Claude; dat kan alleen in een terminal (bash cel/pc/start.sh)"
    return 1
  fi
  printf '\a'
  say ""
  say "${B}Nu één keer inloggen bij Claude${N} (met je Claude-abonnement: Pro, Max, Team of Enterprise)."
  say "  - Er opent een browser, of je krijgt een link: open die (Ctrl+klik) en log in."
  say "  - Toont de browser een code? Kopieer hem en plak hem hier (rechtermuisknop of Ctrl+Shift+V), dan Enter."
  "$CLAUDE_BIN" auth login 9>&-
  logged_in && { goed "ingelogd"; return 0; }
  say ""
  say "Dat lukte zo niet. Ik start Claude zelf: log daar in (kies je Claude-abonnement, niet een API-sleutel)"
  say "en typ daarna /exit om hier verder te gaan."
  "$CLAUDE_BIN" 9>&-
  logged_in && { goed "ingelogd"; return 0; }
  fout "nog steeds niet ingelogd"
  return 1
}
# state of the tmux session: geen | draait | herstart (wrapper waits to restart claude) | dood
rc_state() {
  tm has-session -t "=$SES" 2>/dev/null || { echo geen; return; }
  local pid
  pid=$(tm list-panes -t "=$SES" -F '#{pane_pid}' 2>/dev/null | head -n1)
  if [ -n "$pid" ] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'claude_rc\.sh'; then
    if pgrep -P "$pid" -f 'remote-control' >/dev/null 2>&1; then echo draait; else echo herstart; fi
  else
    echo dood
  fi
}
attach_rc() {
  # attaching can last as long as the user stays in the Claude window: release the start.sh lock first,
  # so Claude itself (bash cel/pc/start.sh --alleen-plan) and other windows are not blocked meanwhile
  if have flock; then flock -u 9 2>/dev/null; exec 9>&-; fi
  if [ -n "${TMUX:-}" ] && [ -z "${OERCEL_TMUX_SOCKET:-}" ]; then tm switch-client -t "=$SES"
  else TMUX='' tm attach -t "=$SES"; fi
}
# does Claude in the tmux window wait for an answer (trust, enable, login, Enter)?  Only what comes after
# the last session link (claude.ai/code/...) counts, and of that the last lines: questions answered before
# the link stay on screen.  (capture-pane needs "=SES:" — tmux 3.4 rejects a bare "=SES".)
rc_asks() {
  tm capture-pane -p -t "=$SES:" 2>/dev/null |
    awk 'NF == 0 { next } /claude\.ai\/code/ { n = 0; next } { l[++n] = $0 } END { for (i = (n > 8 ? n - 7 : 1); i <= n; i++) print l[i] }' |
    grep -qiE '\(y/n\)|\[y/n\]|trust|enable remote|not logged in|log ?in (to|with|first)|auth login|/login|press enter|enter to (confirm|continue)|paste|choose'
}
offer_attach() {    # $1 = why; shows the instructions, then switches to the Claude window (terminal only)
  if ! interactive; then
    let_op "Claude wacht in tmux op een antwoord; beantwoord dat in een terminal:  tmux attach -t $SES"
    noteer "Remote Control" "wacht op een antwoord (tmux attach -t $SES)"
    return 0
  fi
  say ""
  say "${B}${1:+$1 }Zo schakel ik naar het Claude-venster.${N} Beantwoord daar de vragen met ${B}y${N} en Enter:"
  say "    Enable Remote Control? (y/n)            ->  y"
  say "    Trust ... ? / vertrouw je deze map?     ->  y"
  say "    andere vraag (kleuren, 'Press Enter')   ->  Enter"
  say "  Zie je de sessie-link (claude.ai/code/...), dan is het klaar."
  say "  ${B}Terug naar hier: Ctrl+b indrukken, loslaten, dan d.${N}  Claude blijft dan gewoon draaien."
  read -r -t "${OERCEL_ATTACH_WAIT:-30}" -p "  Druk op Enter om naar Claude te gaan ... " _ || true
  : > "$STATE/claude_rc_eerder_gestart"
  attach_rc
  say ""
  say "Terug uit het Claude-venster."
  sleep 1
  if [ "$(rc_state)" = geen ]; then
    let_op "het Claude-venster is gesloten; Claude draait niet. Opnieuw: bash cel/pc/start.sh"
  elif rc_asks; then
    let_op "Claude wacht nog op een antwoord. Later beantwoorden: tmux attach -t $SES   (of start.sh opnieuw)"
  fi
}
start_rc() {
  kop "5. Claude Remote Control"
  if [ -z "$CLAUDE_BIN" ] && ! find_claude; then fout "Claude Code ontbreekt (zie stap 2)"; noteer "Remote Control" "FOUT: geen claude"; return 1; fi
  if [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    let_op "ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN is gezet; Remote Control werkt alleen met je abonnement. Ik negeer die variabele voor Claude (haal hem eventueel uit ~/.bashrc)."
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  fi
  local st
  st=$(rc_state)
  case "$st" in
    draait)
      goed "Claude Remote Control draait al in tmux-sessie '$SES' (geen tweede gestart)."
      noteer "Remote Control" "draait al (tmux '$SES')"
      # e.g. the first time the window was left (Ctrl+b d) before the questions were answered
      if rc_asks; then offer_attach "Claude wacht daar nog op een antwoord."
      else say "  Bekijken: tmux attach -t $SES   (terug: Ctrl+b, loslaten, dan d)"; fi
      return 0 ;;
    herstart)
      if [ -f "$STATE/claude_rc.wacht" ]; then
        # the wrapper waits 10 minutes after repeated quick failures (network? login?): try again now
        let_op "Claude Remote Control mislukte een paar keer snel achter elkaar (log: ${STATE#"$REPO"/}/claude_rc.log); ik probeer het nu opnieuw"
        tm kill-session -t "=$SES" 2>/dev/null
      else
        goed "Claude Remote Control in tmux-sessie '$SES' wordt zo vanzelf herstart (geen tweede gestart)."
        noteer "Remote Control" "herstart vanzelf (tmux '$SES')"
        return 0
      fi ;;
    dood)
      say "  tmux-sessie '$SES' bestaat maar Claude draait er niet meer in: opnieuw starten"
      tm kill-session -t "=$SES" 2>/dev/null ;;
  esac
  login_claude || let_op "zonder inloggen start Remote Control niet; in het tmux-venster zie je de melding"
  if ! have tmux; then apt_install tmux || true; fi
  if ! have tmux; then
    fout "tmux ontbreekt en kon niet geïnstalleerd worden."
    if interactive; then
      say "  Dan draait Claude Remote Control nu in DIT venster: laat het open. (Stoppen: Ctrl+C)"
      noteer "Remote Control" "in dit venster (geen tmux)"
      ( cd "$REPO" && "$CLAUDE_BIN" remote-control --name "$RC_NAME" ) 9>&-
    fi
    return 1
  fi
  local first=0 cont=1
  [ -f "$STATE/claude_rc_eerder_gestart" ] || { first=1; cont=0; }
  # the environment for the wrapper goes through a file: an already running tmux server has its own
  # environment, and its shell need not be bash
  { printf 'export HOME=%q PATH=%q CLAUDE_BIN=%q\n' "$HOME" "$PATH" "$CLAUDE_BIN"
    printf 'export OERCEL_START_STATE=%q OERCEL_CLAUDE_NAME=%q OERCEL_CLAUDE_CONTINUE=%q\n' "$STATE" "$RC_NAME" "$cont"
    [ -n "${OERCEL_RC_RESTART_S:-}" ] && printf 'export OERCEL_RC_RESTART_S=%q\n' "$OERCEL_RC_RESTART_S"
    [ -n "${OERCEL_RC_BACKOFF_S:-}" ] && printf 'export OERCEL_RC_BACKOFF_S=%q\n' "$OERCEL_RC_BACKOFF_S"
  } > "$STATE/claude_rc.env"
  if ! tm new-session -d -s "$SES" -c "$REPO" -x 160 -y 48 "exec bash '$PC_DIR/claude_rc.sh' '$STATE/claude_rc.env'"; then
    fout "tmux-sessie '$SES' starten mislukt"; noteer "Remote Control" "FOUT: tmux"; return 1
  fi
  goed "tmux-sessie '$SES' gestart: claude remote-control --name \"$RC_NAME\" (in $REPO)"
  noteer "Remote Control" "gestart (tmux '$SES')"
  local need=$first
  if [ "$need" = 0 ]; then
    # not the first time: only show the window when Claude asks something (login, trust, enable)
    sleep "${OERCEL_RC_PEEK_S:-6}"
    rc_asks && need=1
  fi
  if [ "$need" = 1 ] && interactive; then
    : > "$STATE/claude_rc_eerder_gestart"
    offer_attach ""
    return 0
  fi
  [ "$need" = 1 ] && offer_attach ""     # no terminal: only the hint
  # without a terminal the first-time questions are still unanswered: keep 'first' for the next start
  if [ "$first" = 0 ] || interactive; then : > "$STATE/claude_rc_eerder_gestart"; fi
}

# ------------------------------------------------------------------------------------ uitvoeren
if [ "$DO_CLAUDE" = 1 ]; then install_claude; fi
if [ "$DO_PLAN" = 1 ]; then
  if [ "$PLAN_DONE" = 1 ]; then run_plan "3. Experimenten (plan nog eens, na de installatie)"
  else run_plan "3. Experimenten (cel/pc/plan.txt)"; fi
fi
kop "4. Status"
python3 "$PC_DIR/status.py" --kort 9>&- || true
if [ "$DO_CLAUDE" = 1 ]; then start_rc; fi

kop "Samenvatting"
for l in "${RESULT[@]}"; do say "  $l"; done
say ""
if [ "$DO_CLAUDE" = 1 ] && [ "$(rc_state)" != geen ]; then
  say "Claude draait in tmux-sessie '$SES'. Open de Claude-app (of claude.ai/code) -> Code -> '$RC_NAME'."
  say "  Even kijken in dit venster: tmux attach -t $SES     terug: Ctrl+b, dan d"
fi
say "Status:   python3 cel/pc/status.py          Stoppen: bash cel/pc/stop.sh   (alles, ook Claude: --alles)"
[ "$PATH_ADDED" = 1 ] && say "Zelf 'claude' typen kan in een nieuw Ubuntu-venster (in dit venster eerst: source ~/.bashrc)."
case "$REPO" in "$HOME"/*) RSHOW="~/${REPO#"$HOME"/}" ;; *) RSHOW=$REPO ;; esac
say "Na een herstart van de pc: open Ubuntu en typ weer   cd $RSHOW && bash cel/pc/start.sh"
say "Laat dit Ubuntu-venster open (minimaliseren mag): als alle Ubuntu-vensters dicht zijn kan Windows WSL stoppen."
exit 0
