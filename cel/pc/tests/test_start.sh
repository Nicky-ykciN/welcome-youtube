#!/bin/bash
# start.sh / stop.sh / plan.py end-to-end, with stand-ins so it runs on any Linux machine:
#   nep-HOME, nep-claude (+ nep-installer via een nep-curl), nep-nvidia-smi + nep-GPU-engine (= de CPU-engine),
#   nep-setup_wsl.sh (OERCEL_SETUP_CMD), de echte tmux op een eigen socket (-L), runs in een eigen map.
# Getest:
#   1. eerste start in een (pseudo)terminal: setup 1x, Claude geïnstalleerd + PATH in ~/.bashrc, inloggen
#      (code plakken), plan gestart (terugvalregel zonder production.ini, GPU-run + sweep), status,
#      Remote Control in tmux, 'Enable Remote Control? (y/n)' beantwoord, Ctrl+b d terug
#   2. meteen nog eens: niets dubbel (setup/installer niet opnieuw, plan 'draait al', één Claude)
#   3. kill -9 van supervisors + engines (stroomstoring) -> start.sh hervat beide
#   4. stop.sh -> alles netjes gestopt (checkpoint), start.sh hervat; bewuste --stop blijft staan
#   5. production.ini verschijnt terwijl de run bestaat -> melding, run gaat door met eigen instellingen
#   6. production.ini voor een nieuwe run -> 'als'-regel gekozen
#   7. GPU weg -> nieuwe GPU-regel wacht, onderbroken GPU-run wordt niet hervat
#   8. installatie mislukt -> eerst hervatten, dan setup opnieuw; na succes niet meer
#   9. runs buiten het plan: onderbroken -> hervat, bewust gestopt -> blijft staan
#  10. repo op de "Windows-schijf" -> verder in de kopie in ~
#  11. planbestand: fouten, 'als niet', vervolgregels
#  12. stop.sh --alles -> tmux weg; start.sh -> Claude opnieuw (met --continue), geen vraag dus geen attach
#  13. Claude stopt in tmux -> de wrapper start hem opnieuw; tmux-sessie zonder Claude -> vervangen
#  14. klaar + het plan wil meer stappen -> hervat tot het nieuwe doel
#  15. vraag in tmux niet beantwoord (te vroeg Ctrl+b d) -> start.sh brengt je terug; het slot is vrij tijdens attach
#  16. GitHub: (in 1 en 2 al: eenmalig gh auth login --hostname github.com --git-protocol https --web na de
#      Claude-login, eerst gh's vraag "Authenticate Git...?" en dan de code, Windows-browser via explorer.exe,
#      credential-helper, git-naam/e-mail uit gh api user, geen token in de repo; opnieuw = geen tweede login)
#      niet ingelogd zonder terminal -> één regel; Ctrl+C -> start.sh gaat door; login mislukt; oude gh zonder
#      --git-protocol (browser via BROWSER); plaatsvervangende identiteit, later vervangen; eigen identiteit blijft;
#      remote geen github.com; gh ontbreekt; --alleen-plan raakt GitHub niet; ingelogd maar GitHub onbereikbaar ->
#      geen nieuwe loginvraag (ook oude gh); token ongeldig en GitHub bereikbaar -> wel opnieuw inloggen
#  17. longrun.py: zonder --width kiest render.py de breedte (geen --width doorgegeven, time-lapse 2400); met
#      --width precies die; oude toestand (versie 1, width 2000) -> automatisch, andere waarde blijft
#  18. setup_wsl.sh (droog, in een kopie): gh uit GitHubs officiële repository (ook als Ubuntu een oud pakket heeft;
#      onbereikbaar -> Ubuntu-pakket; oude gh bijwerken, nieuwe laten staan), tools/selftest.py PASS/FAIL in de
#      samenvatting (zonder ffmpeg alleen video-fout -> waarschuwing), overgeslagen met --snel/--geen-tests
# usage: bash cel/pc/tests/test_start.sh [outdir]      (default cel/pc/_test/start; ~5-15 minuten, 1-2 threads)
set -u
CEL=$(cd "$(dirname "$0")/../.." && pwd)
PC=$CEL/pc
T=${1:-$PC/_test/start}
SOCK=oercel_test_$$
rm -rf "$T"; mkdir -p "$T/bin" "$T/home" "$T/runs" "$T/beelden" "$T/state" "$T/setup_logs"
T=$(cd "$T" && pwd)
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

# ------------------------------------------------------------------------------ stand-ins
cat > "$T/bin/claude_fake" <<'EOF'
#!/bin/bash
# nep-claude voor de test van start.sh (doet niets echt)
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
echo "$(date +%T) pid $$: $*" >> "$HOME/fake_claude.log"
case "${1:-}" in
  --version) echo "9.9.9 (Claude Code, NEP)" ;;
  doctor) echo "alles ok (nep)" ;;
  auth)
    [ "${2:-}" = login ] || exit 2
    echo "Browser didn't open? Use the url below to sign in: https://claude.ai/oauth/authorize?nep"
    printf 'Paste code here if prompted > '
    read -r code
    [ -n "$code" ] || exit 1
    mkdir -p "$cfg"; echo '{"nep": true}' > "$cfg/.credentials.json"; echo "Login successful." ;;
  remote-control)
    [ -s "$cfg/.credentials.json" ] || { echo "Not logged in. Run: claude auth login" >&2; exit 1; }
    if [ ! -f "$cfg/nep_rc_aan" ]; then
      printf 'Enable Remote Control? (y/n) '
      read -r a
      [ "$a" = y ] || exit 1
      touch "$cfg/nep_rc_aan"
    fi
    echo "Remote Control actief: https://claude.ai/code/session_fake  ($*)"
    while :; do
      if [ -f "$cfg/nep_rc_stop" ]; then rm -f "$cfg/nep_rc_stop"; echo "verbinding weg (nep)"; exit 3; fi
      sleep 0.5
    done ;;
  *) echo "nep-claude interactief"; read -r _ ;;
esac
EOF
cat > "$T/bin/curl" <<EOF
#!/bin/bash
# nep-curl: levert alleen de 'installer' van de nep-claude (en 'GitHub bereikbaar' voor de nep-proef-URL)
for a in "\$@"; do
  case "\$a" in *nep-github-bereikbaar*) exit 0 ;; esac      # start.sh: "is GitHub bereikbaar?"
  case "\$a" in *install.sh)
    echo "\$(date +%T) installer" >> "\$HOME/fake_install.log"
    echo 'mkdir -p "\$HOME/.local/bin" && cp "$T/bin/claude_fake" "\$HOME/.local/bin/claude" && chmod +x "\$HOME/.local/bin/claude" && echo "Claude Code (NEP) installed to ~/.local/bin/claude"'
    exit 0 ;;
  esac
done
exit 22
EOF
cat > "$T/bin/fake_setup.sh" <<'EOF'
#!/bin/bash
# nep-setup_wsl.sh: schrijft alleen een log zoals het echte script (laatste regels)
d=$OERCEL_SETUP_LOGDIR; mkdir -p "$d"; LOG=$d/setup_$(date +%Y%m%d_%H%M%S)_$$.log
echo "$(date +%T) tty=$([ -t 0 ] && echo ja || echo nee) resultaat=${FAKE_SETUP_RESULT:-ok}" >> "$HOME/fake_setup_calls.log"
{ echo "Oercel setup (NEP) — log: $LOG"; echo; echo "=== SAMENVATTING ==="
  [ "${FAKE_SETUP_RESULT:-ok}" = gpu ] && echo "  FOUT          GPU              nvidia-smi werkt niet in WSL2. Installeer/actualiseer de NVIDIA-driver in WINDOWS"
  if [ "${FAKE_SETUP_RESULT:-ok}" = ok ]; then echo "Klaar. Volgende stap: start Claude Code in de repo"; else echo "1 onderdeel/onderdelen met FOUT (zie boven en $LOG)."; fi
} | tee "$LOG"
[ "${FAKE_SETUP_RESULT:-ok}" = ok ]
EOF
mkdir -p "$T/gpubin"
cat > "$T/gpubin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in
  *--query-gpu=name,memory.total,memory.used*) echo "Quadro RTX 8000 (NEP), 49152, 900, 97, 60";;
  *--query-compute-apps*) ;;
  *) echo "| NVIDIA-SMI 565.77.01   Driver Version: 566.14   CUDA Version: 12.7 |";;
esac
EOF
printf '#!/bin/bash\n# nep-GPU-engine: de CPU-engine\nexec %s "$@"\n' "$CEL/engine/oercel" > "$T/bin/gpu_ok"
# nep-gh (GitHub CLI): inloggen met een 'code', setup-git schrijft de credential-helper in ~/.gitconfig, api user.
# Zoals de echte gh (cli/cli pkg/cmd/auth/shared/login_flow.go): in een terminal met --git-protocol https vraagt hij
# EERST "Authenticate Git with your GitHub credentials? (Y/n)" (niet als gh al de helper is), dan pas de code.
# FAKE_GH_OLD=1: zoals gh 2.4.0 (Ubuntu 22.04): geen --git-protocol, met --web geen vragen, browser alleen via
#   BROWSER (niet GH_BROWSER), geen 'auth token', token in ~/.config/gh/hosts.yml
# FAKE_GH_RESULT=fout: inloggen mislukt.  FAKE_GH_OFFLINE=1: GitHub onbereikbaar (status/api falen, token blijft)
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'EOF2'
#!/bin/bash
d=$HOME/.nep_gh; mkdir -p "$d"
echo "$(date +%T) $*" >> "$HOME/fake_gh.log"
old=${FAKE_GH_OLD:-0}
case "$1 ${2:-}" in
  "--version ") [ "$old" = 1 ] && echo "gh version 2.4.0+dfsg1 (2022-03-23 Ubuntu 2.4.0+dfsg1-2)" || echo "gh version 9.9.9 (NEP)" ;;
  "auth status")
    if [ -s "$d/token" ] && [ "${FAKE_GH_OFFLINE:-0}" = 1 ]; then
      echo "github.com"; echo "  X Timeout trying to log in to github.com account nepuser (nep)" >&2; exit 1; fi
    if [ -s "$d/token" ]; then echo "github.com"; echo "  ✓ Logged in to github.com account nepuser (nep)"; exit 0; fi
    echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1 ;;
  "auth token")
    [ "$old" = 1 ] && { echo 'unknown command "token" for "gh auth"' >&2; exit 1; }
    [ -s "$d/token" ] && { cat "$d/token"; exit 0; }
    echo "no oauth token found for github.com" >&2; exit 1 ;;
  "auth login")
    if [ "${3:-}" = --help ]; then
      echo "FLAGS"; echo "  -h, --hostname string   The hostname of the GitHub instance to authenticate with"
      [ "$old" = 1 ] || echo "  -p, --git-protocol string   The protocol to use for git operations on this host: {ssh|https}"
      echo "  -w, --web   Open a browser to authenticate"; exit 0
    fi
    for a in "$@"; do [ "$a" = --git-protocol ] && [ "$old" = 1 ] && { echo "unknown flag: --git-protocol" >&2; exit 1; }; done
    setup=0
    if [ "$old" != 1 ] && [ -t 0 ] && case " $* " in *" --git-protocol https "*) true ;; *) false ;; esac &&
       ! git config --global --get-all credential.https://github.com.helper 2>/dev/null | grep -q 'auth git-credential'; then
      printf '? Authenticate Git with your GitHub credentials? (Y/n) '
      read -r ans || exit 1
      case "$ans" in ""|y|Y|yes) setup=1 ;; esac
    fi
    echo "! First copy your one-time code: NEP1-2345"
    printf 'Press Enter to open https://github.com/login/device in your browser... '
    read -r _ || exit 1
    if [ "$old" = 1 ]; then br=${BROWSER:-}; else br=${GH_BROWSER:-${BROWSER:-}}; fi
    if [ -n "$br" ]; then $br https://github.com/login/device || echo "! Failed opening a web browser"; fi
    [ "${FAKE_GH_RESULT:-ok}" = ok ] || { echo "error: authentication failed (nep)" >&2; exit 1; }
    echo "nep-token-GEHEIM-0123" > "$d/token"
    if [ "$old" = 1 ]; then mkdir -p "$HOME/.config/gh"; printf 'github.com:\n    oauth_token: nep-token-GEHEIM-0123\n    user: nepuser\n' > "$HOME/.config/gh/hosts.yml"; fi
    case " $* " in *" --git-protocol https "*) echo https > "$d/git_protocol" ;; esac
    if [ "$setup" = 1 ]; then
      git config --global --replace-all credential.https://github.com.helper ''
      git config --global --add credential.https://github.com.helper "!$0 auth git-credential"
    fi
    echo "✓ Authentication complete."; echo "✓ Logged in as nepuser" ;;
  "auth setup-git")
    git config --global --replace-all credential.https://github.com.helper ''
    git config --global --add credential.https://github.com.helper "!$0 auth git-credential" ;;
  "config get") [ "$*" = "config get -h github.com git_protocol" ] && cat "$d/git_protocol" 2>/dev/null ;;
  "config set") [ "$*" = "config set -h github.com git_protocol https" ] && echo https > "$d/git_protocol" ;;
  "api user")
    [ -s "$d/token" ] || { echo "gh: Requires authentication (HTTP 401)" >&2; exit 1; }
    [ "${FAKE_GH_OFFLINE:-0}" = 1 ] && { echo "error connecting to api.github.com (nep)" >&2; exit 1; }
    if [ "${3:-}" = --jq ]; then echo nepuser
    else echo '{"login":"nepuser","id":12345,"name":"Nep  Gebruiker","email":null,"type":"User"}'; fi ;;
  *) echo "nep-gh: onbekend: $*" >&2; exit 2 ;;
esac
EOF2
# nep-explorer.exe (WSL: opent een URL in de Windows-browser; de echte geeft altijd code 1)
printf '#!/bin/bash\necho "$*" >> "$HOME/fake_explorer.log"\nexit 1\n' > "$T/bin/explorer.exe"
chmod +x "$T/bin/"* "$T/gpubin/"* "$T/ghbin/"*
# git-repo voor de GitHub-stap (start.sh mag de echte repo niet aanpassen): remote op github.com, geen identiteit
newrepo() { rm -rf "$1"; git init -q "$1" && git -C "$1" remote add origin "${2:-https://github.com/Nicky-ykciN/welcome-youtube}"; }
newrepo "$T/gitrepo"
REAL_GITCFG=$(cksum < "$CEL/../.git/config" 2>/dev/null)

cat > "$T/pty_drive.py" <<'EOF'
# drives a command in a pseudo-terminal: waits for each text and then types the answer
import json, os, pty, re, select, signal, struct, sys, time, fcntl, termios
steps = json.loads(os.environ["PTY_STEPS"]); timeout = float(os.environ.get("PTY_TIMEOUT", "300"))
log = open(os.environ["PTY_LOG"], "wb")
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execvp(sys.argv[1], sys.argv[1:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
ansi = re.compile(r"\x1b(\[[0-9;?>=]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[()][0-9A-Za-z]|[=>78DEHMc])")
buf, i, t0, done = "", 0, time.time(), []
while True:
    if time.time() - t0 > timeout:
        os.kill(pid, signal.SIGTERM); done.append("TIMEOUT"); break
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data); log.flush()
        buf += ansi.sub("", data.decode("utf-8", "replace"))
    if i < len(steps):
        k = buf.find(steps[i][0])
        if k >= 0:
            time.sleep(0.7)
            for part in steps[i][1].split("\u0001"):
                os.write(fd, part.encode()); time.sleep(0.3)
            done.append(steps[i][0]); buf = buf[k + len(steps[i][0]):]; i += 1
_, status = os.waitpid(pid, 0)
print(json.dumps({"rc": os.waitstatus_to_exitcode(status), "done": done, "missing": [s[0] for s in steps[i:]]}))
EOF

# ------------------------------------------------------------------------------ environment
BASEPATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=$T/home PATH=$T/gpubin:$BASEPATH
export OERCEL_RUNS=$T/runs OERCEL_BEELDEN=$T/beelden OERCEL_NO_BUILD=1 OERCEL_PLAN=$T/plan.txt
export OERCEL_SETUP_LOGDIR=$T/setup_logs OERCEL_START_STATE=$T/state OERCEL_SETUP_CMD="bash $T/bin/fake_setup.sh"
export OERCEL_TMUX_SOCKET=$SOCK OERCEL_TMUX_SESSION=oercel-claude OERCEL_TEST_NO_APT=1 OERCEL_RC_PEEK_S=3
export OERCEL_ENGINE_GPU=$T/bin/gpu_ok OERCEL_GPU_SELFTEST_FILE=$T/gpu_selftest.json OERCEL_GPU_SMOKE_FILE=$T/gpu_smoke.json
export OERCEL_ATTACH_WAIT=20 OERCEL_RC_RESTART_S=1
export OERCEL_GH=$T/ghbin/gh OERCEL_TEST_GIT_REPO=$T/gitrepo GIT_CONFIG_NOSYSTEM=1 OERCEL_GITHUB_PROBE=https://nep-github-weg.invalid/
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR TMUX TMUX_PANE
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR GH_BROWSER BROWSER XDG_CONFIG_HOME
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
touch "$HOME/.bashrc"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  for d in "$T"/runs/*; do
    [ -f "$d/pc_longrun.json" ] && python3 "$PC/longrun.py" "$(basename "$d")" --stop >/dev/null 2>&1
    [ -f "$d/pc_sweep.json" ] && python3 "$PC/sweep.py" --stop "$(basename "$d")" >/dev/null 2>&1
  done
}
trap cleanup EXIT

GSTEPS=250000
LR="--threads 1 --chunk-min 0.05 --analyse-uur 0 --geen-beelden --analyse-jobs 1 --poll 0.3 --backoff 0.2"
OV="init=soup L=32 snap_every=10000 stats_every=1000 log_every=10000 ckpt_every=5000"
cat > "$T/scan.txt" <<'EOF'
# kleine sweep voor de test
naam  = scan
basis = engine/params/membranes.ini
seeds = 1 2
steps = 30000
zet   = L=24 chem=1 events=1 snap_every=10000 stats_every=1000 log_every=10000 ckpt_every=5000
zet   = p_syn_a=3e-5 p_syn_b=1e-4 feed=uniform p_feed=1e-4 feed_cap=0.12
EOF
cat > "$T/plan.txt" <<EOF
# testplan (zelfde vorm als cel/pc/plan.txt)
als $T/production.ini bestaat: \\
  longrun.py groot --engine gpu --ini $T/production.ini \\
    --set $OV steps=$GSTEPS \\
    $LR
anders: \\
  longrun.py groot --engine gpu --ini engine/params/membranes.ini \\
    --set $OV steps=$GSTEPS \\
          chem=1 events=1 p_syn_a=3e-5 p_syn_b=1e-4 feed=uniform p_feed=1e-4 feed_cap=0.12 \\
    $LR   # commentaar aan het eind mag
sweep.py $T/scan.txt --threads 1 --jobs 1 --poll 0.3
EOF
S() { bash "$PC/start.sh" "$@" < /dev/null 2>&1; }      # start.sh without a terminal (as Claude would run it)
st() { python3 -c "import json,sys; d=json.load(open('$T/runs/$1/pc_longrun.json')); print(d.get('$2'))" 2>/dev/null; }
sw() { python3 -c "import json,sys; d=json.load(open('$T/runs/$1/pc_sweep.json')); print(d.get('$2'))" 2>/dev/null; }
holder() { python3 -c "import sys; sys.path.insert(0,'$PC'); import pclib as P; print(P.lock_holder('$T/runs/$1') or '')"; }
nsetup() { wc -l < "$HOME/fake_setup_calls.log" 2>/dev/null || echo 0; }
nrc() { pgrep -f "$HOME/.local/bin/claude remote-control" | wc -l; }
wait_for() { local n=$1; shift; local t=0; while ! eval "$*" && [ $t -lt $((n * 2)) ]; do sleep 0.5; t=$((t + 1)); done; eval "$*"; }   # re-evaluates its argument string
kill_run() {   # kill -9 supervisor + engine of runs/$1 (power cut)
  local h; h=$(holder "$1")
  local eng; eng=$(python3 -c "import sys; sys.path.insert(0,'$PC'); import pclib as P; print(' '.join(map(str, P.engine_pids_for('$T/runs/$1'))))")
  [ -n "$h" ] && kill -9 "$h" 2>/dev/null
  for e in $eng; do kill -9 "$e" 2>/dev/null; done
  for j in "$T/runs/$1"/*/; do
    for e in $(python3 -c "import sys; sys.path.insert(0,'$PC'); import pclib as P; print(' '.join(map(str, P.engine_pids_for('$j'))))"); do kill -9 "$e" 2>/dev/null; done
  done
}

# ------------------------------------------------------------------------------ 1. first start
echo "== 1. eerste start in een terminal =="
PTY_LOG=$T/s1.pty PTY_TIMEOUT=300 PTY_STEPS='[["Paste code here", "NEPCODE\r"], ["Authenticate Git with your GitHub credentials? (Y/n)", "\r"], ["Press Enter to open", "\r"], ["naar Claude te gaan", "\r"], ["(y/n)", "y\r"], ["session_fake", "\u0002\u0001d"]]' \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" > "$T/s1.json"
python3 - "$T/s1.pty" > "$T/s1.txt" <<'EOF'
import re, sys
t = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
print(re.sub(r"\x1b(\[[0-9;?>=]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[()][0-9A-Za-z]|[=>78DEHMc])", "", t).replace("\r", ""))
EOF
cat "$T/s1.json"
check "start.sh eindigde met code 0 en alle vragen werden gesteld" python3 -c "import json; d=json.load(open('$T/s1.json')); assert d['rc']==0 and not d['missing'], d"
check "setup 1x gedraaid, in de terminal" grep -q "tty=ja" "$HOME/fake_setup_calls.log"
check "Claude geïnstalleerd in ~/.local/bin via de installer" test -x "$HOME/.local/bin/claude"
check "~/.bashrc zet ~/.local/bin in PATH" grep -q "oercel-claude-path" "$HOME/.bashrc"
check "ingelogd (credentials)" test -s "$HOME/.claude/.credentials.json"
check "GPU-run gestart met de terugvalregel (geen production.ini)" grep -q "groot (lange run): NIEUW GESTART \[terugvalregel" "$T/s1.txt"
check "  ... membranes.ini + chemie, op de (nep-)GPU" python3 -c "
import json; d=json.load(open('$T/runs/groot/pc_longrun.json'))
assert d['ini_source']=='engine/params/membranes.ini' and d['engine']=='gpu', d
assert d['overrides']['chem']=='1' and d['overrides']['p_syn_a']=='3e-5' and d['overrides']['feed_cap']=='0.12', d['overrides']"
check "sweep gestart" grep -q "scan (sweep): NIEUW GESTART" "$T/s1.txt"
check "status --kort getoond" grep -q "LANGE RUNS" "$T/s1.txt"
check "Remote Control in tmux, met --name 'Oercel werkstation' en zonder --continue" \
  grep -q "remote-control --name Oercel werkstation$" "$HOME/fake_claude.log"
check "tmux-sessie oercel-claude bestaat en Claude draait erin" test "$(nrc)" = 1
check "uitleg Ctrl+b d getoond, en samenvatting na het terugkomen" grep -q "Ctrl+b indrukken, loslaten, dan d" "$T/s1.txt"
grep -q "Terug uit het Claude-venster" "$T/s1.txt" && grep -q "== Samenvatting ==" "$T/s1.txt" && pass "teruggekeerd uit tmux, samenvatting" || fail "geen samenvatting na detach"
ngl() { grep -c "auth login --hostname" "$HOME/fake_gh.log" 2>/dev/null || echo 0; }
check "GitHub: na de Claude-login en vóór het Claude-venster, met uitleg (code, Authorize, Ctrl+C)" python3 -c "
t=open('$T/s1.txt').read(); a=t.find('Login successful'); b=t.find('één keer inloggen bij GitHub'); c=t.find('naar Claude te gaan')
assert 0 <= a < b < c, (a, b, c); assert 'github.com/login/device' in t and 'Authorize' in t and 'Ctrl+C' in t"
check "  ... gh auth login --hostname github.com --git-protocol https --web, precies 1x" \
  bash -c "test \"\$(grep -c 'auth login --hostname github.com --git-protocol https --web$' '$HOME/fake_gh.log')\" = 1"
check "  ... Windows-browser geopend met github.com/login/device (via explorer.exe)" grep -qx "https://github.com/login/device" "$HOME/fake_explorer.log"
check "  ... eerst gh's vraag 'Authenticate Git ...?', dan de code (echte volgorde); Enter = ja" python3 -c "
t=open('$T/s1.txt').read(); a=t.find('Authenticate Git with your GitHub'); b=t.find('one-time code: NEP1-2345')
assert 0 <= a < b, (a, b)"
check "  ... git vraagt gh om de inlog voor github.com (~/.gitconfig; door gh na 'ja')" \
  bash -c "git config --global --get-all credential.https://github.com.helper | grep -q 'auth git-credential'"
check "  ... start.sh deed daarna geen tweede gh auth setup-git (helper herkend)" test "$(grep -c 'auth setup-git' "$HOME/fake_gh.log")" = 0
check "  ... git-identiteit uit gh api user, alleen in deze repo (noreply-adres)" bash -c "
  test \"\$(git -C '$T/gitrepo' config --local user.name)\" = 'Nep Gebruiker' &&
  test \"\$(git -C '$T/gitrepo' config --local user.email)\" = '12345+nepuser@users.noreply.github.com' &&
  ! git config --global user.name >/dev/null"
check "  ... samenvatting: ingelogd bij GitHub" grep -q "GitHub .*ingelogd als nepuser" "$T/s1.txt"
check "  ... geen token in de repo (ook niet in .git)" bash -c "! grep -rq 'nep-token-GEHEIM' '$T/gitrepo'"

# ------------------------------------------------------------------------------ 2. again
echo "== 2. meteen nog eens (zonder terminal) =="
S > "$T/s2.txt"
check "setup niet opnieuw" test "$(nsetup)" = 1
check "installer niet opnieuw" test "$(wc -l < "$HOME/fake_install.log")" = 1
grep -q "installatie: al eerder gelukt" "$T/s2.txt" && pass "meldt: installatie al eerder gelukt" || fail "geen melding installatie"
grep -qE "groot \(lange run\): (draait al|klaar)" "$T/s2.txt" && pass "groot: $(grep -oE 'groot \(lange run\): [a-z ]+' "$T/s2.txt")" || fail "groot niet overgeslagen: $(grep groot "$T/s2.txt")"
grep -qE "scan \(sweep\): (draait al|klaar)" "$T/s2.txt" && pass "scan overgeslagen" || fail "scan niet overgeslagen"
check "Claude: 'draait al', geen tweede gestart" grep -q "draait al in tmux-sessie" "$T/s2.txt"
check "nog steeds precies één Claude" test "$(nrc)" = 1
check "GitHub: geen tweede login, setup-git niet opnieuw" bash -c "test \"\$(grep -c 'auth login --hostname' '$HOME/fake_gh.log')\" = 1 &&
  test \"\$(grep -c 'auth setup-git' '$HOME/fake_gh.log')\" = 0"
check "  ... meldt: ingelogd bij GitHub als nepuser" grep -q "ingelogd bij GitHub als nepuser" "$T/s2.txt"

# ------------------------------------------------------------------------------ 3. power cut
echo "== 3. kill -9 van alles (stroomstoring) -> start.sh hervat =="
wait_for 60 'test -n "$(holder groot)"' >/dev/null
kill_run groot; kill_run scan
sleep 1
S --geen-claude > "$T/s3.txt"
check "groot hervat" grep -q "groot (lange run): HERVAT" "$T/s3.txt"
grep -qE "scan \(sweep\): (HERVAT|klaar)" "$T/s3.txt" && pass "scan: $(grep -oE 'scan \(sweep\): [A-Za-z]+' "$T/s3.txt")" || fail "scan niet hervat: $(grep scan "$T/s3.txt")"
check "groot draait weer" wait_for 20 'test -n "$(holder groot)"'

# ------------------------------------------------------------------------------ 4. stop.sh
echo "== 4. stop.sh en weer start.sh; bewuste --stop blijft staan =="
bash "$PC/stop.sh" > "$T/s4a.txt" 2>&1
check "stop.sh: groot gestopt door stop.sh (status gestopt, merkteken)" python3 -c "
import json, os; d=json.load(open('$T/runs/groot/pc_longrun.json')); assert d['status']=='gestopt' and d['stopped_by']=='gebruiker', d['status']
assert os.path.exists('$T/runs/groot/pc_gestopt_door_stop_sh')"
check "stop.sh laat Claude draaien" test "$(nrc)" = 1
check "status na stop.sh getoond" grep -q "LANGE RUNS" "$T/s4a.txt"
S --geen-claude > "$T/s4b.txt"
check "start.sh hervat wat stop.sh stopte" grep -q "groot (lange run): HERVAT" "$T/s4b.txt"
check "merkteken weg na hervatten" test ! -e "$T/runs/groot/pc_gestopt_door_stop_sh"
wait_for 20 'test -n "$(holder groot)"'
python3 "$PC/longrun.py" groot --stop > /dev/null 2>&1
S --geen-claude > "$T/s4c.txt"
check "bewuste --stop: blijft staan" grep -q "groot (lange run): bewust gestopt met --stop; blijft staan" "$T/s4c.txt"
check "  ... en draait echt niet" test -z "$(holder groot)"
python3 "$PC/longrun.py" groot --achtergrond > /dev/null 2>&1     # by hand further (as Claude would)

# ------------------------------------------------------------------------------ 5. production.ini appears
echo "== 5. production.ini verschijnt terwijl groot bestaat =="
{ grep -v '^ *\(chem\|events\) *=' "$CEL/engine/params/membranes.ini"; printf 'chem = 1\nevents = 1\np_syn_a = 5e-5\np_syn_b = 1.5e-4\nfeed = uniform\np_feed = 1e-4\nfeed_cap = 0.12\n'; } > "$T/production.ini"
S --geen-claude > "$T/s5.txt"
check "melding: gestart met membranes.ini, het plan noemt nu production.ini" grep -q "LET OP: gestart met engine/params/membranes.ini, het plan noemt nu" "$T/s5.txt"
check "groot blijft membranes.ini gebruiken" test "$(st groot ini_source)" = engine/params/membranes.ini

# ------------------------------------------------------------------------------ 6. production.ini, new run
echo "== 6. production.ini voor een nieuwe run =="
cat > "$T/plan6.txt" <<EOF
als $T/production.ini bestaat: longrun.py groot6 --engine gpu --ini $T/production.ini --set $OV steps=3000 $LR
anders: longrun.py groot6 --engine gpu --ini engine/params/membranes.ini --set $OV steps=3000 chem=1 p_syn_a=3e-5 $LR
EOF
OERCEL_PLAN=$T/plan6.txt S --alleen-plan > "$T/s6.txt"
check "'als'-regel gekozen: [production.ini bestaat]" grep -q "groot6 (lange run): NIEUW GESTART \[$T/production.ini bestaat\]" "$T/s6.txt"
check "  ... run gebruikt production.ini en niet de terugval-chemie" python3 -c "
import json; d=json.load(open('$T/runs/groot6/pc_longrun.json')); assert d['ini_source'].endswith('production.ini'), d['ini_source']
assert 'p_syn_a' not in d['overrides'], d['overrides']"
rm -f "$T/production.ini"
OERCEL_PLAN=$T/plan6.txt python3 "$PC/plan.py" lijst > "$T/s6b.txt"
check "zonder production.ini geldt de terugvalregel (plan.py lijst)" grep -q "groot6 (lange run): .*\[anders\]" "$T/s6b.txt"

# ------------------------------------------------------------------------------ 7. no GPU
echo "== 7. GPU weg =="
cat > "$T/plan7.txt" <<EOF
longrun.py groot7 --engine gpu --ini engine/params/membranes.ini --set $OV steps=3000 $LR
EOF
PATH=$BASEPATH OERCEL_PLAN=$T/plan7.txt S --alleen-plan > "$T/s7a.txt"
check "nieuwe GPU-regel wacht op de GPU" grep -q "groot7 (lange run): WACHT OP GPU" "$T/s7a.txt"
check "  ... er is niets aangemaakt" test ! -e "$T/runs/groot7/pc_longrun.json"
wait_for 20 'test -n "$(holder groot)"' > /dev/null
kill_run groot; sleep 0.5
PATH=$BASEPATH S --alleen-plan > "$T/s7b.txt"
check "onderbroken GPU-run niet hervat zonder GPU" grep -q "groot (lange run): WACHT OP GPU — niet hervat" "$T/s7b.txt"
S --alleen-plan > "$T/s7c.txt"
check "GPU terug -> hervat" grep -q "groot (lange run): HERVAT" "$T/s7c.txt"

# ------------------------------------------------------------------------------ 8. setup failed
echo "== 8. installatie mislukt =="
export OERCEL_SETUP_LOGDIR=$T/setup_logs8
FAKE_SETUP_RESULT=fout S --geen-claude > "$T/s8a.txt"
check "eerste poging: setup gedraaid en mislukt, toch door" grep -q "de installatie meldde fouten" "$T/s8a.txt"
FAKE_SETUP_RESULT=fout S --geen-claude > "$T/s8b.txt"
check "tweede start: eerst hervatten, dan setup, dan plan nog eens" python3 -c "
t=open('$T/s8b.txt').read(); a=t.find('Experimenten hervatten (vóór de nieuwe installatiepoging)'); b=t.find('1. Installatie'); c=t.find('plan nog eens')
assert 0 <= a < b < c, (a, b, c)"
FAKE_SETUP_RESULT=fout S --geen-claude > "$T/s8c.txt"
n0=$(nsetup); FAKE_SETUP_RESULT=fout S --geen-claude > "$T/s8d.txt"; n1=$(nsetup)
check "na 3x mislukt op rij niet meer automatisch ($n0 -> $n1)" test "$n1" = "$n0"
check "  ... met uitleg en het commando --setup" grep -q "3x achter elkaar mislukt.*" "$T/s8d.txt"
FAKE_SETUP_RESULT=gpu S --setup --geen-claude > "$T/s8e.txt"
check "--setup forceert een poging" test "$(nsetup)" = $((n1 + 1))
n0=$(nsetup); S --geen-claude > "$T/s8f.txt"; n1=$(nsetup)
check "log zei 'nvidia-smi werkt niet' en nu werkt de GPU: toch opnieuw ($n0 -> $n1)" test "$n1" = $((n0 + 1))
check "  ... met melding" grep -q "De GPU werkt nu wel" "$T/s8f.txt"
S --geen-claude > "$T/s8g.txt"; n2=$(nsetup)
check "na een geslaagde setup niet meer ($n1 -> $n2)" test "$n2" = "$n1"
S --setup --geen-claude > "$T/s8h.txt"
check "--setup na een geslaagde setup: opnieuw, met passende melding" grep -q "Installatie opnieuw (--setup)" "$T/s8h.txt"
export OERCEL_SETUP_LOGDIR=$T/setup_logs

# ------------------------------------------------------------------------------ 9. runs outside the plan
echo "== 9. runs buiten het plan =="
python3 "$PC/longrun.py" los --ini engine/params/membranes.ini --set $OV steps=150000 $LR --engine cpu --achtergrond > /dev/null 2>&1
python3 "$PC/longrun.py" los2 --ini engine/params/membranes.ini --set $OV steps=150000 $LR --engine cpu --achtergrond > /dev/null 2>&1
wait_for 30 'test -n "$(holder los)"' > /dev/null; wait_for 30 'test -n "$(holder los2)"' > /dev/null
sleep 4; kill_run los; python3 "$PC/longrun.py" los2 --stop > /dev/null 2>&1
S --alleen-plan > "$T/s9.txt"
check "onderbroken run buiten het plan: hervat" grep -q "los: HERVAT" "$T/s9.txt"
check "bewust gestopte run buiten het plan: blijft staan" grep -q "los2: bewust gestopt; blijft staan" "$T/s9.txt"
bash "$PC/stop.sh" > "$T/s9b.txt" 2>&1
S --alleen-plan > "$T/s9c.txt"
check "door stop.sh gestopte run buiten het plan: hervat" grep -q "los: HERVAT" "$T/s9c.txt"
python3 "$PC/longrun.py" los --stop > /dev/null 2>&1

# ------------------------------------------------------------------------------ 10. Windows drive
echo "== 10. repo op de Windows-schijf =="
W=$T/winc/repo; mkdir -p "$W/cel/pc" "$T/home_w/repo/cel/pc"
cp "$PC/start.sh" "$W/cel/pc/start.sh"
printf '#!/bin/bash\necho "KOPIE GESTART $*"\n' > "$T/home_w/repo/cel/pc/start.sh"
out=$(HOME=$T/home_w OERCEL_TEST_WINDRIVE=$T/winc bash "$W/cel/pc/start.sh" --alleen-plan < /dev/null 2>&1)
echo "$out" > "$T/s10a.txt"
check "kopie in ~ gevonden en daar verder (met dezelfde opties)" grep -q "KOPIE GESTART --alleen-plan" "$T/s10a.txt"
rm -rf "$T/home_w/repo/cel"; mkdir -p "$T/home_w/repo/iets"
HOME=$T/home_w OERCEL_TEST_WINDRIVE=$T/winc bash "$W/cel/pc/start.sh" --alleen-plan < /dev/null > "$T/s10b.txt" 2>&1
rc=$?
check "map in ~ bestaat maar is geen Oercel-repo: stopt met uitleg (code $rc)" grep -q "die map bestaat al" "$T/s10b.txt"

# ------------------------------------------------------------------------------ 11. plan file
echo "== 11. planbestand =="
printf 'anders: longrun.py x --ini engine/params/membranes.ini\n' > "$T/p11a.txt"
OERCEL_PLAN=$T/p11a.txt python3 "$PC/plan.py" lijst > "$T/s11a.txt" 2>&1
check "'anders:' zonder 'als' geweigerd" grep -q "'anders:' zonder 'als ... bestaat:'" "$T/s11a.txt"
printf 'longrun.py x --stop\n' > "$T/p11b.txt"
OERCEL_PLAN=$T/p11b.txt python3 "$PC/plan.py" lijst > "$T/s11b.txt" 2>&1
check "--stop in het plan geweigerd" grep -q "hoort niet in het plan" "$T/s11b.txt"
printf 'rm -rf /\n' > "$T/p11c.txt"
OERCEL_PLAN=$T/p11c.txt python3 "$PC/plan.py" start > "$T/s11c.txt" 2>&1
check "alleen longrun.py en sweep.py toegestaan" grep -q "verwacht longrun.py of sweep.py" "$T/s11c.txt"
printf '# c\nals niet %s bestaat: \\\n  longrun.py y1 --ini engine/params/membranes.ini \\\n  --set L=24   # c2\nlongrun.py y2 --ini engine/params/membranes.ini\n' "$T/bestaat_niet" > "$T/p11d.txt"
OERCEL_PLAN=$T/p11d.txt python3 "$PC/plan.py" lijst > "$T/s11d.txt" 2>&1
check "'als niet ... bestaat' + vervolgregels + commentaar" grep -q "regel 2   y1 (lange run): nieuw  \[als .*bestaat_niet niet bestaat: nee\]" "$T/s11d.txt"
check "regel na een vervolgregel goed geteld" grep -q "regel 5   y2 (lange run): nieuw" "$T/s11d.txt"

# ------------------------------------------------------------------------------ 12. stop.sh --alles
echo "== 12. stop.sh --alles, daarna start.sh =="
bash "$PC/stop.sh" --alles > "$T/s12a.txt" 2>&1
check "tmux-sessie weg" bash -c "! tmux -L $SOCK has-session -t =oercel-claude 2>/dev/null"
check "geen Claude meer" wait_for 10 'test "$(nrc)" = 0'
S > "$T/s12b.txt"
check "Claude opnieuw gestart in tmux" grep -q "tmux-sessie 'oercel-claude' gestart" "$T/s12b.txt"
check "  ... met --continue (vorige sessie bestond)" wait_for 10 'grep -q "remote-control --name Oercel werkstation --continue" "$HOME/fake_claude.log"'
check "  ... geen vraag in beeld, dus geen attach-melding" bash -c "! grep -q 'wacht in tmux op een antwoord' '$T/s12b.txt'"
check "experimenten hervat (stop.sh-merktekens)" grep -qE "groot \(lange run\): (HERVAT|klaar)" "$T/s12b.txt"

# ------------------------------------------------------------------------------ 13. wrapper restarts claude
echo "== 13. Claude stopt in tmux / sessie zonder Claude =="
n0=$(grep -c "start: claude" "$T/state/claude_rc.log")
touch "$HOME/.claude/nep_rc_stop"
check "wrapper start Claude opnieuw" wait_for 20 'test "$(grep -c "start: claude" "$T/state/claude_rc.log")" -gt "$n0"'
check "  ... en hij draait weer (1x)" wait_for 10 'test "$(nrc)" = 1'
tmux -L "$SOCK" kill-server; sleep 0.5
tmux -L "$SOCK" new-session -d -s oercel-claude "bash --norc"
S > "$T/s13.txt"
check "sessie zonder Claude wordt vervangen" grep -q "Claude draait er niet meer in: opnieuw starten" "$T/s13.txt"
check "  ... en Claude draait" wait_for 10 'test "$(nrc)" = 1'

# ------------------------------------------------------------------------------ 14. more steps
echo "== 14. klaar, en het plan wil meer stappen =="
check "groot wordt klaar ($GSTEPS stappen)" wait_for 300 'test "$(st groot status)" = klaar'
S --alleen-plan > "$T/s14a.txt"
check "klaar -> overgeslagen" grep -q "groot (lange run): klaar" "$T/s14a.txt"
sed -i "s/steps=$GSTEPS/steps=$((GSTEPS + 20000))/" "$T/plan.txt"
S --alleen-plan > "$T/s14b.txt"
check "meer stappen in het plan -> hervat" grep -q "groot (lange run): HERVAT" "$T/s14b.txt"
check "  ... nieuw doel $((GSTEPS + 20000)) opgeslagen" test "$(st groot steps)" = $((GSTEPS + 20000))
check "  ... en gehaald" wait_for 120 'test "$(st groot status)" = klaar'
scan_done() { python3 -c "
import json; d=json.load(open('$T/runs/scan/pc_sweep.json')); s=[v['status'] for v in d['state'].values()]
assert len(s)==2 and all(x=='geanalyseerd' for x in s), s" 2>/dev/null; }
check "sweep scan klaar en geanalyseerd" wait_for 120 scan_done

# ------------------------------------------------------------------------------ 15. question left open
echo "== 15. vraag niet beantwoord (te vroeg Ctrl+b d) -> start.sh brengt je terug; slot vrij tijdens attach =="
bash "$PC/stop.sh" --alles > /dev/null 2>&1
rm -f "$HOME/.claude/nep_rc_aan"          # Claude asks 'Enable Remote Control?' again
PTY_LOG=$T/s15a.pty PTY_TIMEOUT=120 PTY_STEPS='[["naar Claude te gaan", "\r"], ["Remote Control? (y/n)", "\u0002\u0001d"]]' \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s15a.json"
check "later start: vraag in tmux gezien (tmux capture-pane werkt), naar Claude geschakeld" \
  python3 -c "import json; d=json.load(open('$T/s15a.json')); assert d['rc']==0 and not d['missing'], d"
check "  ... na Ctrl+b d zonder antwoord: waarschuwing" grep -q "Claude wacht nog op een antwoord" "$T/s15a.pty"
S --geen-setup > "$T/s15b.txt"
check "  ... start.sh zonder terminal: hint 'tmux attach'" grep -q "Claude wacht in tmux op een antwoord" "$T/s15b.txt"
check "  ... en geen tweede Claude" test "$(nrc)" = 1
( PTY_LOG=$T/s15c.pty PTY_TIMEOUT=120 PTY_STEPS='[["naar Claude te gaan", "\r"], ["session_fake", "\u0002\u0001d"]]' \
    python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s15c.json" ) &
p15=$!
wait_for 60 'tmux -L $SOCK capture-pane -p -t =oercel-claude: 2>/dev/null | grep -q "Remote Control? (y/n)" && grep -qs "naar Claude te gaan" "$T/s15c.pty"' > /dev/null
sleep 2
S --alleen-plan > "$T/s15d.txt"
check "start.sh --alleen-plan werkt terwijl de gebruiker in het Claude-venster zit (slot vrijgegeven)" \
  bash -c "! grep -q 'start.sh draait al' '$T/s15d.txt' && grep -q 'Experimentplan' '$T/s15d.txt'"
tmux -L "$SOCK" send-keys -t =oercel-claude: y Enter
wait $p15
check "draait al + open vraag -> opnieuw naar Claude geschakeld, beantwoord, terug" \
  python3 -c "import json; d=json.load(open('$T/s15c.json')); assert d['rc']==0 and not d['missing'], d"
check "  ... 'Claude wacht daar nog op een antwoord' gemeld" grep -q "Claude wacht daar nog op een antwoord" "$T/s15c.pty"
check "  ... geen valse waarschuwing na het beantwoorden" bash -c "! grep -q 'Claude wacht nog op een antwoord' '$T/s15c.pty'"
check "  ... nog steeds precies één Claude" test "$(nrc)" = 1

# ------------------------------------------------------------------------------ 16. GitHub
echo "== 16. GitHub-login: overslaan, mislukken, oude gh, identiteit, andere remote, geen gh =="
ngh() { wc -l < "$HOME/fake_gh.log"; }
gh_logout() { rm -f "$HOME/.nep_gh/token" "$HOME/.config/gh/hosts.yml"; }
gh_logout
n0=$(ngl); S --geen-setup > "$T/s16a.txt"
check "niet ingelogd, geen terminal: geen loginpoging" test "$(ngl)" = "$n0"
check "  ... één regel: pushen kan pas na gh auth login" grep -q "pushen naar GitHub kan nog niet: typ later in Ubuntu  gh auth login" "$T/s16a.txt"
check "  ... in de samenvatting" grep -q "GitHub .*niet ingelogd: pushen kan pas na  gh auth login" "$T/s16a.txt"
PTY_LOG=$T/s16b.pty PTY_TIMEOUT=120 PTY_STEPS='[["Press Enter to open", "\u0003"]]' \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s16b.json"
check "Ctrl+C tijdens de GitHub-login: start.sh gaat door tot het eind (code 0)" \
  python3 -c "import json; d=json.load(open('$T/s16b.json')); assert d['rc']==0 and not d['missing'], d"
check "  ... samenvatting + regel 'pushen kan nog niet'" bash -c "grep -q '== Samenvatting ==' '$T/s16b.pty' && grep -q 'pushen naar GitHub kan nog niet' '$T/s16b.pty'"
check "  ... niet ingelogd" test ! -s "$HOME/.nep_gh/token"
check "  ... Claude draait nog (1x): Ctrl+C raakte alleen gh" test "$(nrc)" = 1
PTY_LOG=$T/s16c.pty PTY_TIMEOUT=120 PTY_STEPS='[["Press Enter to open", "\r"]]' FAKE_GH_RESULT=fout \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s16c.json"
check "login mislukt: start.sh gaat door (code 0) met de regel 'pushen kan nog niet'" bash -c "
  python3 -c \"import json; d=json.load(open('$T/s16c.json')); assert d['rc']==0 and not d['missing'], d\" &&
  grep -q 'pushen naar GitHub kan nog niet' '$T/s16c.pty'"
git config --global --unset-all credential.https://github.com.helper; rm -f "$HOME/.nep_gh/git_protocol"
nexp=$(wc -l < "$HOME/fake_explorer.log")
PTY_LOG=$T/s16d.pty PTY_TIMEOUT=120 PTY_STEPS='[["Press Enter to open", "\r"]]' FAKE_GH_OLD=1 \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s16d.json"
check "oude gh (leest alleen BROWSER, niet GH_BROWSER): Windows-browser toch geopend via explorer.exe" \
  test "$(wc -l < "$HOME/fake_explorer.log")" = "$((nexp + 1))"
check "oude gh (zoals 2.4.0, Ubuntu 22.04): login zonder --git-protocol" bash -c "
  python3 -c \"import json; d=json.load(open('$T/s16d.json')); assert d['rc']==0 and not d['missing'], d\" &&
  tail -n 12 '$HOME/fake_gh.log' | grep -q 'auth login --hostname github.com --web$' && test -s '$HOME/.nep_gh/token'"
check "  ... daarna git_protocol https (gh config set) en setup-git opnieuw" bash -c "
  grep -qx https '$HOME/.nep_gh/git_protocol' && git config --global --get-all credential.https://github.com.helper | grep -q 'auth git-credential'"
check "  ... eigen (eerder gezette) identiteit van de repo blijft" test "$(git -C "$T/gitrepo" config user.name)" = "Nep Gebruiker"
newrepo "$T/gitrepo2"; gh_logout
OERCEL_TEST_GIT_REPO=$T/gitrepo2 S --geen-setup > "$T/s16e.txt"
check "zonder GitHub-login: plaatsvervanger 'Oercel werkstation <oercel@localhost>' (lokaal), zodat commits werken" bash -c "
  test \"\$(git -C '$T/gitrepo2' config --local user.name)\" = 'Oercel werkstation' &&
  test \"\$(git -C '$T/gitrepo2' config --local user.email)\" = 'oercel@localhost' &&
  git -C '$T/gitrepo2' commit -q --allow-empty -m test"
echo "nep-token-GEHEIM-0123" > "$HOME/.nep_gh/token"
OERCEL_TEST_GIT_REPO=$T/gitrepo2 S --geen-setup > "$T/s16f.txt"
check "  ... later ingelogd: plaatsvervanger vervangen door het GitHub-account" bash -c "
  test \"\$(git -C '$T/gitrepo2' config user.name)\" = 'Nep Gebruiker' &&
  test \"\$(git -C '$T/gitrepo2' config user.email)\" = '12345+nepuser@users.noreply.github.com'"
newrepo "$T/gitrepo3"; git -C "$T/gitrepo3" config user.name "Echte Naam"; git -C "$T/gitrepo3" config user.email "echt@voorbeeld.nl"
OERCEL_TEST_GIT_REPO=$T/gitrepo3 S --geen-setup > "$T/s16g.txt"
check "eigen identiteit van de gebruiker wordt nooit veranderd" bash -c "
  test \"\$(git -C '$T/gitrepo3' config user.name)\" = 'Echte Naam' && test \"\$(git -C '$T/gitrepo3' config user.email)\" = 'echt@voorbeeld.nl'"
newrepo "$T/gitrepo4" "$T/ergens/anders.git"; gh_logout
n0=$(ngh); OERCEL_TEST_GIT_REPO=$T/gitrepo4 S --geen-setup > "$T/s16h.txt"
check "remote is geen github.com: GitHub-login overgeslagen, gh niet aangeroepen" bash -c "
  grep -q 'GitHub-login overgeslagen' '$T/s16h.txt' && test \"\$(wc -l < '$HOME/fake_gh.log')\" = '$n0'"
check "  ... wel een identiteit voor commits" test "$(git -C "$T/gitrepo4" config user.name)" = "Oercel werkstation"
OERCEL_GH=$T/geen/gh S --geen-setup > "$T/s16i.txt"
check "gh ontbreekt: één regel (installeren, dan gh auth login), start.sh gaat door" bash -c "
  grep -q 'pushen naar GitHub kan nog niet: gh ontbreekt' '$T/s16i.txt' && grep -q '== Samenvatting ==' '$T/s16i.txt'"
n0=$(ngh); S --alleen-plan > "$T/s16j.txt"
check "--alleen-plan (Claude) raakt GitHub niet aan" bash -c "test \"\$(wc -l < '$HOME/fake_gh.log')\" = '$n0' && ! grep -q 'GitHub' '$T/s16j.txt'"
# ingelogd, maar GitHub nu onbereikbaar (bv. net na een herstart): 'gh auth status' faalt dan ook met een geldig token
gh_logout; echo "nep-token-GEHEIM-0123" > "$HOME/.nep_gh/token"; n0=$(ngl)
PTY_LOG=$T/s16k.pty PTY_TIMEOUT=120 PTY_STEPS='[]' FAKE_GH_OFFLINE=1 \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s16k.json"
check "ingelogd maar GitHub onbereikbaar (in een terminal): geen nieuwe loginvraag, start.sh gaat door (code 0)" bash -c "
  python3 -c \"import json; d=json.load(open('$T/s16k.json')); assert d['rc']==0, d\" && test \"\$(grep -c 'auth login --hostname' '$HOME/fake_gh.log')\" = '$n0' &&
  grep -q 'GitHub is nu niet bereikbaar' '$T/s16k.pty' && grep -q 'GitHub .*eerder ingelogd; nu niet bereikbaar' '$T/s16k.pty' &&
  ! grep -q 'inloggen bij GitHub' '$T/s16k.pty'"
mkdir -p "$HOME/.config/gh"; printf 'github.com:\n    oauth_token: nep-token-GEHEIM-0123\n    user: nepuser\n' > "$HOME/.config/gh/hosts.yml"
PTY_LOG=$T/s16l.pty PTY_TIMEOUT=120 PTY_STEPS='[]' FAKE_GH_OFFLINE=1 FAKE_GH_OLD=1 \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > /dev/null
check "  ... ook met oude gh zonder 'auth token' (token in ~/.config/gh/hosts.yml)" bash -c "
  test \"\$(grep -c 'auth login --hostname' '$HOME/fake_gh.log')\" = '$n0' && grep -q 'GitHub is nu niet bereikbaar' '$T/s16l.pty'"
PTY_LOG=$T/s16m.pty PTY_TIMEOUT=120 PTY_STEPS='[["Press Enter to open", "\u0003"]]' FAKE_GH_OFFLINE=1 OERCEL_GITHUB_PROBE=https://nep-github-bereikbaar.invalid/ \
  python3 "$T/pty_drive.py" bash "$PC/start.sh" --geen-setup > "$T/s16m.json"
check "token opgeslagen, status faalt, GitHub wel bereikbaar (token ongeldig): wel opnieuw inloggen" bash -c "
  python3 -c \"import json; d=json.load(open('$T/s16m.json')); assert d['rc']==0 and not d['missing'], d\" &&
  test \"\$(grep -c 'auth login --hostname' '$HOME/fake_gh.log')\" = '$((n0 + 1))'"
check "geen token in de (test-)repo's of in de logs van start.sh" bash -c "! grep -rqs 'nep-token-GEHEIM' '$T'/gitrepo* '$T/state' '$T'/s1*.txt '$T'/s1*.pty"
check "de echte repo is niet aangepast (.git/config)" test "$(cksum < "$CEL/../.git/config" 2>/dev/null)" = "$REAL_GITCFG"

# ------------------------------------------------------------------------------ 17. image width
echo "== 17. longrun.py: beeldbreedte automatisch, tenzij gezet =="
python3 - "$PC" > "$T/s17a.txt" 2>&1 <<'EOF2'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import longrun as L
import pclib as P
calls = []
def fake_render_one(self, args, out, what):
    calls.append(args)
    return False
L.Supervisor.render_one = fake_render_one
P.interesting_track = lambda rd: (7, 1000)
d = tempfile.mkdtemp()
def args_for(width):
    calls.clear()
    st = dict(settings=dict(L.SETTINGS_DEFAULTS), beelden_dir=d, last_analysis_step=1000)
    if width is not None:
        st["settings"]["width"] = width
    sup = L.Supervisor(os.path.join(d, "run"), st, open(os.devnull, "w"))
    sup.save = lambda: None
    sup.render(dict(divisions=1, divisions_confirmed=1, division_steps=[500]))
    return {a[a.index("--kind") + 1]: a for a in calls}
ok = True
a = args_for(None)
ok &= L.SETTINGS_DEFAULTS["width"] is None
ok &= "--width" not in a["micro"] and "--width" not in a["goodsell"]
ok &= a["timelapse"][a["timelapse"].index("--width") + 1] == "2400"
b = args_for(3000)
ok &= b["micro"][b["micro"].index("--width") + 1] == "3000" and b["goodsell"][b["goodsell"].index("--width") + 1] == "3000"
ok &= b["timelapse"][b["timelapse"].index("--width") + 1] == "3000"
c = args_for(1000)
ok &= c["timelapse"][c["timelapse"].index("--width") + 1] == "2400" and c["micro"][c["micro"].index("--width") + 1] == "1000"
print("auto:", a); print("3000:", b); print("1000:", c)
print("OK" if ok else "FOUT")
EOF2
check "render-argumenten: auto = geen --width (time-lapse 2400); gezet = die breedte (time-lapse min. 2400)" grep -qx OK "$T/s17a.txt"
pngw() { python3 -c "import struct,sys; print(struct.unpack('>I', open(sys.argv[1],'rb').read(24)[16:20])[0])" "$1"; }
W17="init=soup L=24 snap_every=1000 stats_every=500 log_every=1000 ckpt_every=1000"
L17="--threads 1 --chunk-min 0.05 --analyse-uur 0 --analyse-jobs 1 --poll 0.3 --backoff 0.2 --engine cpu"
python3 "$PC/longrun.py" wauto --ini engine/params/membranes.ini --set $W17 steps=2000 $L17 > "$T/s17b.txt" 2>&1
python3 "$PC/longrun.py" wvast --ini engine/params/membranes.ini --set $W17 steps=2000 $L17 --width 640 > "$T/s17c.txt" 2>&1
check "zonder --width: opgeslagen als automatisch (None), toestand versie 2" \
  python3 -c "import json; d=json.load(open('$T/runs/wauto/pc_longrun.json')); assert d['settings']['width'] is None and d['version']==2 and d['status']=='klaar', d['settings']"
check "  ... render.py zonder --width aangeroepen, beeld 2000 px breed (render.py's keuze)" bash -c "
  grep 'render.py' '$T/runs/wauto/pc_tools.log' | grep -q -- '--kind micro' && ! grep 'render.py' '$T/runs/wauto/pc_tools.log' | grep -q -- '--width' &&
  test \"\$(ls '$T/beelden/wauto'/micro_*.png | wc -l)\" = 1 && test \"\$(python3 -c \"import struct,glob; print(struct.unpack('>I', open(glob.glob('$T/beelden/wauto/micro_*.png')[0],'rb').read(24)[16:20])[0])\")\" = 2000"
check "met --width 640: opgeslagen, doorgegeven en het beeld is 640 px breed" bash -c "
  python3 -c \"import json; d=json.load(open('$T/runs/wvast/pc_longrun.json')); assert d['settings']['width']==640\" &&
  grep 'render.py' '$T/runs/wvast/pc_tools.log' | grep -q -- '--width 640' &&
  test \"\$(python3 -c \"import struct,glob; print(struct.unpack('>I', open(glob.glob('$T/beelden/wvast/micro_*.png')[0],'rb').read(24)[16:20])[0])\")\" = 640"
python3 - "$T/runs" <<'EOF2'
import json, sys
for name, w in (("wauto", 2000), ("wvast", 1500)):      # as the old longrun.py (version 1) stored it
    p = f"{sys.argv[1]}/{name}/pc_longrun.json"; d = json.load(open(p))
    d["version"] = 1; d["settings"]["width"] = w
    json.dump(d, open(p, "w"))
EOF2
python3 "$PC/longrun.py" wauto --steps 3000 > "$T/s17d.txt" 2>&1
python3 "$PC/longrun.py" wvast --steps 3000 > "$T/s17e.txt" 2>&1
check "oude toestand (versie 1) met de oude standaard 2000: nu automatisch, zonder --width" bash -c "
  python3 -c \"import json; d=json.load(open('$T/runs/wauto/pc_longrun.json')); assert d['settings']['width'] is None and d['version']==2 and d['steps']==3000 and d['status']=='klaar', d\" &&
  test \"\$(grep 'render.py' '$T/runs/wauto/pc_tools.log' | grep -c -- '--kind micro')\" = 2 && ! grep 'render.py' '$T/runs/wauto/pc_tools.log' | grep -q -- '--width'"
check "oude toestand met een gekozen breedte (1500): blijft 1500" bash -c "
  python3 -c \"import json; d=json.load(open('$T/runs/wvast/pc_longrun.json')); assert d['settings']['width']==1500 and d['version']==2, d['settings']\" &&
  grep 'render.py' '$T/runs/wvast/pc_tools.log' | tail -n1 | grep -q -- '--width 1500'"

# ------------------------------------------------------------------------------ 18. setup_wsl.sh
echo "== 18. setup_wsl.sh (droog, zonder root, in een kopie): gh en tools/selftest.py =="
M=$T/mock; rm -rf "$M"; mkdir -p "$M/cel/pc" "$M/cel/notes/membranen"
for f in setup_wsl.sh env.sh pclib.py status.py cuda_check.cu; do cp -p "$PC/$f" "$M/cel/pc/"; done
cp -a "$CEL/engine" "$M/cel/engine"; cp -a "$CEL/tools" "$M/cel/tools"; rm -rf "$M/cel/tools/__pycache__"
cp "$CEL/notes/membranen/teamA_membranes.ini" "$M/cel/notes/membranen/"
printf '#!/bin/bash\n# nep-validate.sh (de echte duurt minuten; hier gaat het om tools/selftest.py)\necho "PASS  nep-validatie"\n' > "$M/cel/engine/tests/validate.sh"
GHL_BEFORE=$(ls /etc/apt/sources.list.d/github-cli.list /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null)
su18() { env -u OERCEL_RUNS -u OERCEL_BEELDEN OERCEL_TEST_NO_ROOT=1 OERCEL_TEST_NO_GH=1 bash "$M/cel/pc/setup_wsl.sh" --droog --geen-cuda "$@" 2>&1; }
OERCEL_TEST_GH_CANDIDATE=2.45.0-1ubuntu0.3 su18 > "$T/s18a.txt"; rc18a=$?
sed -n '/=== SAMENVATTING ===/,$p' "$T/s18a.txt"
check "tools/selftest.py gedraaid: PASS in de samenvatting (code $rc18a)" bash -c "
  grep -qE '^  OK +tools-zelftest +tools/selftest.py: PASS \([0-9]+ controles' '$T/s18a.txt' && grep -q '^    PASS' '$T/s18a.txt'"
check "  ... werkmap opgeruimd, log bewaard" bash -c "test ! -e '$M/cel/runs/_setup/tools_selftest' && grep -q '^PASS' '$M/cel/runs/_setup/tools_selftest.log'"
check "gh: GitHubs officiële repository eerst, ook als Ubuntu een (oud) pakket heeft (droog: alleen getoond)" bash -c "
  grep -q 'github-cli.list: deb \[arch=[a-z0-9]* signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg\] https://cli.github.com/packages stable main' '$T/s18a.txt' &&
  grep -q 'GitHub CLI .*droog: gh zou worden geïnstalleerd (GitHubs officiële repository)' '$T/s18a.txt' &&
  ! grep -q 'install --no-install-recommends gh$' '$T/s18a.txt'"
OERCEL_TEST_GH_CANDIDATE=none su18 --snel > "$T/s18b.txt"
check "--snel: tools/selftest.py overgeslagen" grep -qE '^  OVERGESLAGEN +tools-zelftest' "$T/s18b.txt"
check "gh zonder Ubuntu-pakket: GitHubs officiële repository (sleutel in /etc/apt/keyrings, signed-by, stable main)" bash -c "
  grep -q 'cli.github.com/packages/githubcli-archive-keyring.gpg' '$T/s18b.txt' &&
  grep -q 'github-cli.list: deb \[arch=[a-z0-9]* signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg\] https://cli.github.com/packages stable main' '$T/s18b.txt' &&
  grep -q 'GitHub CLI .*officiële repository' '$T/s18b.txt'"
check "  ... (droog) niets in /etc geschreven" test "$(ls /etc/apt/sources.list.d/github-cli.list /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null)" = "$GHL_BEFORE"
su18 --geen-tests > "$T/s18c.txt"
check "--geen-tests: tools/selftest.py overgeslagen" grep -qE '^  OVERGESLAGEN +tools-zelftest' "$T/s18c.txt"
OERCEL_TEST_GH_CANDIDATE=2.45.0-1ubuntu0.3 OERCEL_TEST_GH_REPO_FAIL=1 su18 --geen-tests > "$T/s18e.txt"
check "gh: GitHubs repository onbereikbaar -> terugval op Ubuntu's pakket" bash -c "
  grep -q '\[droog\] .*apt-get .* install --no-install-recommends gh$' '$T/s18e.txt' &&
  grep -q 'GitHub CLI .*droog: gh zou worden geïnstalleerd (Ubuntu-pakket 2.45.0-1ubuntu0.3, terugval)' '$T/s18e.txt'"
OERCEL_TEST_GH_VERSION=2.45.0 su18 --geen-tests > "$T/s18f.txt"
check "gh 2.45.0 al aanwezig (Ubuntu 24.04, volgens cli/cli kapot): bijwerken via GitHubs repository" bash -c "
  grep -q 'gh 2.45.0 is oud' '$T/s18f.txt' && grep -q 'https://cli.github.com/packages stable main' '$T/s18f.txt'"
OERCEL_TEST_GH_VERSION=2.89.0 su18 --geen-tests > "$T/s18g.txt"
check "gh 2.89.0 al aanwezig: niets gedaan" bash -c "
  grep -qE '^  OK +GitHub CLI +al aanwezig: gh 2.89.0' '$T/s18g.txt' && ! grep -q 'cli.github.com' '$T/s18g.txt'"
cat > "$M/cel/tools/selftest.py" <<'EOF2'
print("PASS  nep-controle 1")
print("FAIL  nep-controle 2 (bewust)")
raise SystemExit(1)
EOF2
su18 --geen-apt > "$T/s18d.txt"; rc18d=$?
check "tools/selftest.py faalt: FOUT met FAIL en aantallen in de samenvatting, setup-code 1 ($rc18d)" bash -c "
  grep -qE '^  FOUT +tools-zelftest +tools/selftest.py: FAIL \(1 van 2 controles' '$T/s18d.txt' && grep -q 'nep-controle 2' '$T/s18d.txt' && test $rc18d = 1"
check "--geen-apt: gh niet geïnstalleerd -> waarschuwing (geen fout)" grep -qE '^  WAARSCHUWING +GitHub CLI +gh ontbreekt' "$T/s18d.txt"
cat > "$M/cel/tools/selftest.py" <<'EOF2'
print("PASS  nep-controle 1")
print("FAIL  video.py maakt een geldige MP4")
raise SystemExit(1)
EOF2
OERCEL_TEST_NO_FFMPEG=1 su18 --geen-apt > "$T/s18h.txt"; rc18h=$?
check "zonder ffmpeg faalt alleen de video-controle: WAARSCHUWING (zoals ffmpeg zelf), geen FOUT (code $rc18h)" bash -c "
  grep -qE '^  WAARSCHUWING +tools-zelftest +tools/selftest.py: PASS \(1 controles\), alleen video.py faalt: ffmpeg ontbreekt' '$T/s18h.txt' && test $rc18h = 0"
su18 --geen-apt > "$T/s18i.txt"; rc18i=$?
check "  ... met ffmpeg is diezelfde video-fout wél een FOUT (code $rc18i)" bash -c "grep -qE '^  FOUT +tools-zelftest' '$T/s18i.txt' && test $rc18i = 1"
rm -rf "$M"

echo "== $fails fout(en) =="
exit $fails
