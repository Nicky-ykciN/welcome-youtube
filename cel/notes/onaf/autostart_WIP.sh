#!/usr/bin/env bash
# Oercel — vanzelf verder na een herstart van Windows, en Ubuntu wakker houden als alle vensters dicht zijn.
#
#     bash cel/pc/autostart.sh aan       aanzetten: Windows-taak aanmaken (of bijwerken) en meteen starten
#     bash cel/pc/autostart.sh uit       uitzetten: Windows-taak verwijderen en het wakker houden stoppen
#                                        (bash cel/pc/stop.sh --alles doet dit ook)
#     bash cel/pc/autostart.sh status    laten zien hoe het ervoor staat
#     bash cel/pc/autostart.sh wakker    wat de Windows-taak zelf start (niet zelf typen)
#
# Waarom: WSL legt Ubuntu ~15 seconden nadat het laatste Windows-programma dat Ubuntu gebruikt (het Ubuntu-venster,
# wsl.exe) gestopt is stil — ook als er nog simulaties draaien (WSL kijkt alleen naar die Windows-processen,
# niet naar processen in Linux).  En na een herstart van Windows start Ubuntu pas als iemand het opent.
# Daarom maakt 'aan' — alleen als jij dat typt; start.sh doet het nooit zelf — één taak in de Windows-Taakplanner
# (alleen voor deze Windows-gebruiker, geen beheerder nodig):
# bij het aanmelden bij Windows (en daarna elke 10 minuten, als hij niet meer loopt) start hij onzichtbaar
#     wslg.exe -d <distro> -u <gebruiker> --cd <repo> -- /bin/bash <repo>/cel/pc/autostart.sh wakker
# ('wakker' draait start.sh --automatisch en blijft dan wachten: zolang dat wslg.exe-proces bestaat, houdt WSL
# Ubuntu aan).  Zonder wslg.exe (oude WSL): conhost.exe --headless wsl.exe ... --exec.
# Logboek: cel/pc/_build/autostart.log (status.py toont de laatste regels).
# Exitcodes van 'aan': 0 aan, 1 fout, 3 geen WSL (niet nodig).
set -u -o pipefail

PC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CEL=$(dirname "$PC_DIR")
REPO=$(dirname "$CEL")
STATE=${OERCEL_START_STATE:-$PC_DIR/_build}
LOG=$STATE/autostart.log            # wat de verborgen taak deed (Nederlandse regels)
PIDF=$STATE/autostart.pid           # pid van 'wakker' (het proces dat Ubuntu wakker houdt)
INFO=$STATE/autostart_taak.txt      # naam + controlegetal van de aangemaakte Windows-taak
RUNLOG=$STATE/autostart_start.log   # volledige uitvoer van de laatste start.sh --automatisch
REPEAT=${OERCEL_AUTOSTART_REPEAT:-PT10M}

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
log() {
  mkdir -p "$STATE" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  # keep the log small (a reboot a day for years)
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
}
pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
wakker_pid() {      # pid of the running 'wakker' process, if any
  local p
  p=$(cat "$PIDF" 2>/dev/null) || return 1
  pid_alive "$p" && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'autostart\.sh wakker' && { echo "$p"; return 0; }
  return 1
}

# ------------------------------------------------------------------------------------ Windows from WSL
in_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
winexe() {          # a Windows program: via PATH (WSL appends the Windows PATH), else the usual place
  local p d
  p=$(command -v "$1" 2>/dev/null) && { echo "$p"; return 0; }
  for d in /mnt/c/Windows/System32 /mnt/c/WINDOWS/system32; do
    [ -f "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}
WINCWD=/
[ -d /mnt/c ] && WINCWD=/mnt/c       # cmd.exe complains about a Linux (UNC) working directory
win_env() {         # value of a Windows environment variable (e.g. USERPROFILE, ProgramFiles, TEMP)
  local cmd v
  cmd=$(winexe cmd.exe) || return 1
  v=$(cd "$WINCWD" && "$cmd" /d /c "echo %$1%" 2>/dev/null </dev/null | tr -d '\r' | tail -n 1)
  [ -n "$v" ] && [ "$v" != "%$1%" ] && printf '%s' "$v"
}
to_linux() { wslpath -u "$1" 2>/dev/null; }
distro_name() {     # WSL_DISTRO_NAME, else from \\wsl.localhost\<distro>\ (wslpath -w /)
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then printf '%s' "$WSL_DISTRO_NAME"; return 0; fi
  local w
  w=$(wslpath -w / 2>/dev/null | tr -d '\r') || return 1
  w=${w#\\\\}; w=${w#*\\}; w=${w%%\\*}
  [ -n "$w" ] && printf '%s' "$w"
}
task_name() {       # one task per distribution
  local d
  d=$(distro_name) || return 1
  printf 'Oercel-autostart-%s' "$(printf '%s' "$d" | tr -c 'A-Za-z0-9._-' '_')"
}
win_user() {        # DOMAIN\user of the Windows account that runs this (for the logon trigger)
  local w u
  if w=$(winexe whoami.exe); then
    u=$(cd "$WINCWD" && "$w" 2>/dev/null </dev/null | tr -d '\r' | tail -n 1)
    case "$u" in *\\*) printf '%s' "$u"; return 0 ;; esac
  fi
  local dom name
  dom=$(win_env USERDOMAIN); name=$(win_env USERNAME)
  [ -n "$name" ] && printf '%s' "${dom:+$dom\\}$name"
}
xesc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }
schtasks() {        # schtasks.exe without the "UNC path" warning; output in the Windows code page -> only codes are used
  (cd "$WINCWD" && "$SCHT" "$@" </dev/null)
}

# what the task starts: Command + Arguments (sets ACT_CMD, ACT_ARGS, ACT_KIND)
task_action() {
  local d u pf sr exe
  d=$(distro_name) || return 1
  u=$(id -un)
  local script="$PC_DIR/autostart.sh"
  pf=$(win_env ProgramFiles)
  if [ -n "$pf" ] && exe=$(to_linux "$pf\\WSL\\wslg.exe") && [ -f "$exe" ]; then
    # wslg.exe = wsl.exe without a console window; it runs the command through the login shell
    ACT_KIND=wslg
    ACT_CMD="$pf\\WSL\\wslg.exe"
    ACT_ARGS="-d $d -u $u --cd \"$REPO\" -- /bin/bash '$script' wakker"
    return 0
  fi
  sr=$(win_env SystemRoot)
  if [ -n "$sr" ] && exe=$(to_linux "$sr\\System32\\conhost.exe") && [ -f "$exe" ] && \
     exe=$(to_linux "$sr\\System32\\wsl.exe") && [ -f "$exe" ]; then
    # older WSL without wslg.exe: a console host without a window
    ACT_KIND=conhost
    ACT_CMD="$sr\\System32\\conhost.exe"
    ACT_ARGS="--headless \"$sr\\System32\\wsl.exe\" -d $d -u $u --cd \"$REPO\" --exec /bin/bash \"$script\" wakker"
    return 0
  fi
  return 1
}

task_xml() {        # $1 = Windows user (DOMAIN\name)
  local who; who=$(xesc "$1")
  cat <<EOF
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Oercel (cel/pc/start.sh)</Author>
    <Description>Oercel: bij het aanmelden Ubuntu (WSL) starten, de experimenten hervatten en Ubuntu wakker houden (ook met alle vensters dicht). Uitzetten in Ubuntu: bash cel/pc/autostart.sh uit</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>$REPEAT</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <UserId>$who</UserId>
      <Delay>PT30S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$who</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(xesc "$ACT_CMD")</Command>
      <Arguments>$(xesc "$ACT_ARGS")</Arguments>
    </Exec>
  </Actions>
</Task>
EOF
}

need_tools() {      # sets SCHT; prints what is missing
  local miss=()
  SCHT=$(winexe schtasks.exe) || miss+=(schtasks.exe)
  winexe cmd.exe >/dev/null || miss+=(cmd.exe)
  have wslpath || miss+=(wslpath)
  [ ${#miss[@]} -eq 0 ] && return 0
  say "  kan de Windows-taak niet maken of veranderen: ${miss[*]} niet gevonden"
  say "  (staan Windows-programma's starten vanuit Ubuntu uit? /etc/wsl.conf [interop] enabled=false)"
  return 1
}

# ------------------------------------------------------------------------------------ aan
cmd_aan() {
  if ! in_wsl; then
    say "  geen WSL: automatisch starten via Windows is hier niet nodig"
    return 3
  fi
  need_tools || return 1
  local name who xml sum
  name=$(task_name) || { say "  naam van de Ubuntu-distributie onbekend (WSL_DISTRO_NAME leeg, wslpath -w / werkt niet)"; return 1; }
  who=$(win_user) || who=""
  [ -n "$who" ] || { say "  Windows-gebruikersnaam onbekend (whoami.exe en %USERNAME% gaven niets)"; return 1; }
  task_action || { say "  wslg.exe en conhost.exe/wsl.exe niet gevonden (via %ProgramFiles% en %SystemRoot%)"; return 1; }
  xml=$(task_xml "$who")
  sum=$(printf '%s' "$xml" | sha1sum | cut -c1-12)
  if [ "$(sed -n 's/^taak=//p' "$INFO" 2>/dev/null)" = "$name" ] && [ "$(sed -n 's/^controle=//p' "$INFO" 2>/dev/null)" = "$sum" ] &&
     schtasks /Query /TN "$name" >/dev/null 2>&1; then
    say "  Windows-taak '$name' bestaat al (ongewijzigd)"
  else
    # schtasks /XML wants UTF-16 (with BOM); the file must be readable for Windows: its TEMP directory
    local tw tl f fw rc out
    tw=$(win_env TEMP); tl=""
    [ -n "$tw" ] && tl=$(to_linux "$tw")
    if [ -n "$tl" ] && [ -d "$tl" ] && [ -w "$tl" ]; then f=$tl/oercel_autostart_$$.xml; fw="$tw\\oercel_autostart_$$.xml"
    else f=$STATE/oercel_autostart_$$.xml; fw=$(wslpath -w "$f" 2>/dev/null); fi
    if have iconv; then { printf '\xff\xfe'; printf '%s\n' "$xml" | iconv -f UTF-8 -t UTF-16LE; } > "$f"
    else printf '%s\n' "$xml" | python3 -c 'import sys; sys.stdout.buffer.write("\ufeff".encode("utf-16-le") + sys.stdin.read().encode("utf-16-le"))' > "$f"; fi
    out=$(schtasks /Create /TN "$name" /XML "$fw" /F 2>&1); rc=$?
    rm -f "$f"
    if [ "$rc" != 0 ]; then
      say "  Windows-taak '$name' aanmaken mislukte (schtasks code $rc): $(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | cut -c1-200)"
      log "aanmaken van Windows-taak $name mislukt (code $rc)"
      return 1
    fi
    printf 'taak=%s\ncontrole=%s\nsoort=%s\ngebruiker=%s\ndistro=%s\ngemaakt=%s\n' "$name" "$sum" "$ACT_KIND" "$who" \
      "$(distro_name)" "$(date '+%Y-%m-%d %H:%M')" > "$INFO"
    say "  Windows-taak '$name' aangemaakt: bij het aanmelden bij Windows start Oercel vanzelf (onzichtbaar, via $ACT_KIND.exe)"
    log "Windows-taak $name aangemaakt ($ACT_KIND, gebruiker $who)"
  fi
  # keep Ubuntu awake now as well (the user is logged in already: the logon trigger comes only next time)
  if wakker_pid >/dev/null; then
    say "  Ubuntu wordt al wakker gehouden (pid $(wakker_pid)); je mag alle Ubuntu-vensters sluiten"
  elif schtasks /Run /TN "$name" >/dev/null 2>&1; then
    local t=0
    while ! wakker_pid >/dev/null && [ $t -lt "${OERCEL_AUTOSTART_WAIT:-40}" ]; do sleep 0.5; t=$((t + 1)); done
    if wakker_pid >/dev/null; then say "  taak nu gestart: Ubuntu blijft wakker, ook als je alle Ubuntu-vensters sluit"
    else say "  taak gestart; het wakker houden is nog niet te zien (zie straks: bash cel/pc/autostart.sh status)"; fi
  else
    say "  de taak nu meteen starten lukte niet (schtasks /Run); hij start bij de volgende aanmelding"
  fi
  return 0
}

# ------------------------------------------------------------------------------------ uit
cmd_uit() {
  local p name rc=0
  if p=$(wakker_pid); then
    kill "$p" 2>/dev/null
    say "  wakker houden gestopt (pid $p)"
  fi
  name=$(sed -n 's/^taak=//p' "$INFO" 2>/dev/null)
  [ -z "$name" ] && in_wsl && name=$(task_name 2>/dev/null)
  if [ -n "$name" ] && in_wsl; then
    if need_tools >/dev/null; then
      if ! schtasks /Query /TN "$name" >/dev/null 2>&1; then
        say "  Windows-taak '$name' bestond niet (meer)"
      elif schtasks /Delete /TN "$name" /F >/dev/null 2>&1; then
        say "  Windows-taak '$name' verwijderd: na een herstart start Oercel niet meer vanzelf"
        log "Windows-taak $name verwijderd"
      else
        say "  Windows-taak '$name' verwijderen mislukte; doe het zelf in Windows: Taakplanner -> Bibliotheek -> $name -> Verwijderen"
        rc=1
      fi
    else
      need_tools; rc=1
    fi
  fi
  [ "$rc" = 0 ] && rm -f "$INFO"
  [ "$rc" = 0 ] && say "  automatisch starten staat uit (weer aan: bash cel/pc/autostart.sh aan)"
  return "$rc"
}

# ------------------------------------------------------------------------------------ status
cmd_status() {
  local name p
  name=$(sed -n 's/^taak=//p' "$INFO" 2>/dev/null)
  if [ -n "$name" ]; then say "automatisch starten: AAN (Windows-taak '$name', $(sed -n 's/^gemaakt=//p' "$INFO"))"
  elif in_wsl; then say "automatisch starten: UIT (aanzetten: bash cel/pc/autostart.sh aan)"
  else say "automatisch starten: niet van toepassing (geen WSL)"; fi
  if [ -n "$name" ] && in_wsl && SCHT=$(winexe schtasks.exe); then
    schtasks /Query /TN "$name" >/dev/null 2>&1 && say "  de taak staat in de Windows-Taakplanner" ||
      say "  LET OP: de taak staat NIET (meer) in de Windows-Taakplanner; opnieuw: bash cel/pc/autostart.sh aan"
  fi
  if p=$(wakker_pid); then say "  Ubuntu wordt wakker gehouden (pid $p, sinds $(ps -o lstart= -p "$p" 2>/dev/null | sed 's/^ *//'))"
  else say "  Ubuntu wordt nu niet wakker gehouden (sluit je alle Ubuntu-vensters, dan stopt WSL na ~15 s)"; fi
  if [ -s "$LOG" ]; then say "  laatste regels van ${LOG#"$REPO"/}:"; tail -n 8 "$LOG" | sed 's/^/    /'; fi
}

# ------------------------------------------------------------------------------------ wakker
cmd_wakker() {
  mkdir -p "$STATE"
  exec 8>"$STATE/autostart.lock"
  if have flock && ! flock -n 8; then
    log "wakker: draaide al (deze extra start van de taak doet niets)"
    exit 0
  fi
  echo $$ > "$PIDF"
  local sl=""
  # shellcheck disable=SC2317
  stop_wakker() { log "wakker houden gestopt (signaal)"; [ -n "$sl" ] && kill "$sl" 2>/dev/null; rm -f "$PIDF"; exit 0; }
  trap stop_wakker TERM INT HUP
  log "aangemeld bij Windows: automatisch starten (distro ${WSL_DISTRO_NAME:-?}, gebruiker $(id -un))"
  local rc
  bash "$PC_DIR/start.sh" --automatisch > "$RUNLOG" 2>&1 8>&- < /dev/null
  rc=$?
  # the summary of start.sh into the log (status.py shows it)
  sed -n '/== Samenvatting ==/,$p' "$RUNLOG" | sed '1d; /^[[:space:]]*$/d; s/^ *//; s/^/  /' | head -n 12 >> "$LOG"
  log "start.sh --automatisch klaar (code $rc); Ubuntu blijft nu wakker zolang Windows aan is"
  while :; do
    : > "$STATE/autostart.levend"
    sleep "${OERCEL_AUTOSTART_TICK:-300}" 8>&- &
    sl=$!
    wait "$sl"
    sl=""
  done
}

case "${1:-}" in
  aan) cmd_aan ;;
  uit) cmd_uit ;;
  status) cmd_status ;;
  wakker) cmd_wakker ;;
  -h|--help|"") awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; [ -n "${1:-}" ] ;;
  *) say "onbekende opdracht: $1 (aan | uit | status | wakker)"; exit 2 ;;
esac
