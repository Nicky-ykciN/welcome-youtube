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
# usage: bash cel/pc/tests/test_start.sh [outdir]      (default cel/pc/_test/start; ~5-10 minuten, 1 thread)
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
# nep-curl: levert alleen de 'installer' van de nep-claude
for a in "\$@"; do
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
chmod +x "$T/bin/"* "$T/gpubin/"*

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
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR TMUX TMUX_PANE
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
wait_for() { local n=$1; shift; local t=0; while ! "$@" && [ $t -lt $((n * 2)) ]; do sleep 0.5; t=$((t + 1)); done; "$@"; }
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
PTY_LOG=$T/s1.pty PTY_TIMEOUT=300 PTY_STEPS='[["Paste code here", "NEPCODE\r"], ["naar Claude te gaan", "\r"], ["(y/n)", "y\r"], ["session_fake", "\u0002\u0001d"]]' \
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

# ------------------------------------------------------------------------------ 3. power cut
echo "== 3. kill -9 van alles (stroomstoring) -> start.sh hervat =="
wait_for 60 test -n "$(holder groot)" >/dev/null
kill_run groot; kill_run scan
sleep 1
S --geen-claude > "$T/s3.txt"
check "groot hervat" grep -q "groot (lange run): HERVAT" "$T/s3.txt"
grep -qE "scan \(sweep\): (HERVAT|klaar)" "$T/s3.txt" && pass "scan: $(grep -oE 'scan \(sweep\): [A-Za-z]+' "$T/s3.txt")" || fail "scan niet hervat: $(grep scan "$T/s3.txt")"
check "groot draait weer" wait_for 20 test -n "$(holder groot)"

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
wait_for 20 test -n "$(holder groot)"
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
wait_for 20 test -n "$(holder groot)" > /dev/null
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
n0=$(nsetup); S --geen-claude > "$T/s8c.txt"; n1=$(nsetup); S --geen-claude > "$T/s8d.txt"; n2=$(nsetup)
check "na een geslaagde setup niet meer ($n0 -> $n1 -> $n2)" test $((n1 - n0)) = 1 -a $((n2 - n1)) = 0
export OERCEL_SETUP_LOGDIR=$T/setup_logs

# ------------------------------------------------------------------------------ 9. runs outside the plan
echo "== 9. runs buiten het plan =="
python3 "$PC/longrun.py" los --ini engine/params/membranes.ini --set $OV steps=150000 $LR --engine cpu --achtergrond > /dev/null 2>&1
python3 "$PC/longrun.py" los2 --ini engine/params/membranes.ini --set $OV steps=150000 $LR --engine cpu --achtergrond > /dev/null 2>&1
wait_for 30 test -n "$(holder los)" > /dev/null; wait_for 30 test -n "$(holder los2)" > /dev/null
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
check "geen Claude meer" wait_for 10 test "$(nrc)" = 0
S > "$T/s12b.txt"
check "Claude opnieuw gestart in tmux" grep -q "tmux-sessie 'oercel-claude' gestart" "$T/s12b.txt"
check "  ... met --continue (vorige sessie bestond)" wait_for 10 grep -q "remote-control --name Oercel werkstation --continue" "$HOME/fake_claude.log"
check "  ... geen vraag in beeld, dus geen attach-melding" bash -c "! grep -q 'beantwoord die in een terminal' '$T/s12b.txt'"
check "experimenten hervat (stop.sh-merktekens)" grep -qE "groot \(lange run\): (HERVAT|klaar)" "$T/s12b.txt"

# ------------------------------------------------------------------------------ 13. wrapper restarts claude
echo "== 13. Claude stopt in tmux / sessie zonder Claude =="
n0=$(grep -c "start: claude" "$T/state/claude_rc.log")
touch "$HOME/.claude/nep_rc_stop"
check "wrapper start Claude opnieuw" wait_for 20 test "$(grep -c 'start: claude' "$T/state/claude_rc.log")" -gt "$n0"
check "  ... en hij draait weer (1x)" wait_for 10 test "$(nrc)" = 1
tmux -L "$SOCK" kill-server; sleep 0.5
tmux -L "$SOCK" new-session -d -s oercel-claude "bash --norc"
S > "$T/s13.txt"
check "sessie zonder Claude wordt vervangen" grep -q "Claude draait er niet meer in: opnieuw starten" "$T/s13.txt"
check "  ... en Claude draait" wait_for 10 test "$(nrc)" = 1

# ------------------------------------------------------------------------------ 14. more steps
echo "== 14. klaar, en het plan wil meer stappen =="
check "groot wordt klaar ($GSTEPS stappen)" wait_for 300 test "$(st groot status)" = klaar
S --alleen-plan > "$T/s14a.txt"
check "klaar -> overgeslagen" grep -q "groot (lange run): klaar" "$T/s14a.txt"
sed -i "s/steps=$GSTEPS/steps=$((GSTEPS + 20000))/" "$T/plan.txt"
S --alleen-plan > "$T/s14b.txt"
check "meer stappen in het plan -> hervat" grep -q "groot (lange run): HERVAT" "$T/s14b.txt"
check "  ... nieuw doel $((GSTEPS + 20000)) opgeslagen" test "$(st groot steps)" = $((GSTEPS + 20000))
check "  ... en gehaald" wait_for 120 test "$(st groot status)" = klaar
check "sweep scan klaar en geanalyseerd" wait_for 120 python3 -c "
import json; d=json.load(open('$T/runs/scan/pc_sweep.json')); s=[v['status'] for v in d['state'].values()]
assert len(s)==2 and all(x=='geanalyseerd' for x in s), s"

echo "== $fails fout(en) =="
exit $fails
