#!/usr/bin/env bash
# Oercel — installatie op de werkplek (Windows + WSL2 Ubuntu, NVIDIA-GPU).  Veilig om opnieuw te draaien.
#
#   bash cel/pc/setup_wsl.sh            alles: apt-pakketten, Python, CUDA-toolkit, engines bouwen, tests
#   bash cel/pc/setup_wsl.sh --help     opties
#
# Wat het doet (elke stap wordt overgeslagen als hij al gedaan is):
#   1. controleert dat het in WSL2 draait (waarschuwt als de repo onder /mnt/c staat: traag)
#   2. apt: bouwgereedschap, python3 + numpy/scipy/matplotlib/pandas/pillow, ffmpeg, lettertypen
#      (lukt de systeem-Python niet, dan een venv in cel/pc/.venv), en de GitHub CLI 'gh' uit GitHubs officiële
#      apt-repository (start.sh logt daarmee één keer in, zodat Claude resultaten naar GitHub kan pushen)
#   3. CUDA: controleert nvidia-smi (de WINDOWS-driver levert de GPU), installeert dan ALLEEN de
#      cuda-toolkit uit NVIDIA's officiële WSL-Ubuntu-repository, in een versie die de driver aankan.
#      Nooit een Linux-NVIDIA-driver: die pakketten worden met een apt-pin geblokkeerd.
#   4. bouwt engine/oercel (CPU) en engine_gpu/oercel_gpu (GPU, als die map er is)
#   5. draait engine/tests/validate.sh, tools/selftest.py (analyse en beelden op synthetische data),
#      engine_gpu/selftest_gpu.sh (als die er is), een CUDA-test en een korte proefrun met analyse + beeld
#   6. drukt een samenvatting af; log in cel/runs/_setup/
#
# sudo: apt en CUDA hebben root nodig. Draai het script daarom één keer zelf in een terminal (het
# vraagt dan één keer je wachtwoord), of vanuit Windows PowerShell als root:
#     wsl -u root bash ~/<repo>/cel/pc/setup_wsl.sh
# Zonder root (bijv. vanuit Claude Code zonder wachtwoord) doet het alles wat zonder root kan en zegt
# precies wat nog ontbreekt.
set -u -o pipefail

PC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CEL=$(dirname "$PC_DIR")
REPO=$(dirname "$CEL")
DO_APT=1; DO_CUDA=1; DO_TESTS=1; DO_VALIDATE=1; DRY=${OERCEL_DRY:-0}; CUDA_WANT=""; SELFTEST=0
PROC_VERSION=${OERCEL_PROC_VERSION:-/proc/version}
OS_RELEASE=${OERCEL_OS_RELEASE:-/etc/os-release}
NVIDIA_REPO=https://developer.download.nvidia.com/compute/cuda/repos
KEYRING_DEB=cuda-keyring_1.1-1_all.deb
PIN_FILE=/etc/apt/preferences.d/oercel-geen-linux-nvidia-driver
PROFILE_FILE=/etc/profile.d/oercel-cuda.sh

usage() {
  cat <<EOF
gebruik: bash cel/pc/setup_wsl.sh [opties]
  --geen-apt          geen apt-pakketten installeren (alleen controleren)
  --geen-cuda         CUDA-toolkit overslaan (alleen CPU-engine)
  --cuda-versie X-Y   deze toolkit-versie installeren (bijv. 12-6) i.p.v. automatisch kiezen
  --snel              validate.sh (~1-2 min) en tools/selftest.py (~1-2 min) overslaan, GPU-zelftest met
                      --quick; wel bouwen + proefrun
  --geen-tests        geen tests en geen proefrun
  --droog             niets met root uitvoeren of downloaden: alleen tonen wat er zou gebeuren
  --test-functies     interne zelftest van de versiekeuze/parsers (voor ontwikkelaars)
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --geen-apt) DO_APT=0 ;;
    --geen-cuda) DO_CUDA=0 ;;
    --cuda-versie) CUDA_WANT=${2:-}; shift ;;
    --snel) DO_VALIDATE=0 ;;
    --geen-tests) DO_TESTS=0; DO_VALIDATE=0 ;;
    --droog) DRY=1 ;;
    --test-functies) SELFTEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "onbekende optie: $1"; usage; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------------------------- helpers
R_NAME=(); R_STAT=(); R_MSG=()
res() { R_STAT+=("$1"); R_NAME+=("$2"); R_MSG+=("$3"); printf '  -> %-13s %s\n' "$1" "$3"; }
hdr() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# version compare: ver_le A B  (A <= B, dotted or dashed numeric versions)
ver_le() {
  local a=${1//-/.} b=${2//-/.}
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$a" ]
}
# choose the highest toolkit version (X-Y) not above the driver's CUDA version (X.Y)
# usage: choose_toolkit DRIVER_CUDA candidate...   -> prints X-Y or nothing
choose_toolkit() {
  local drv=$1; shift
  local best="" c
  for c in "$@"; do
    [[ "$c" =~ ^[0-9]+-[0-9]+$ ]] || continue
    if ver_le "$c" "$drv"; then
      if [ -z "$best" ] || ver_le "$best" "$c"; then best=$c; fi
    fi
  done
  printf '%s' "$best"
}
# all toolkit versions (X-Y) not above the driver's CUDA version, newest first; with a 3rd argument
# "max12" only CUDA 12.x and older (Ubuntu 20.04: CUDA 13 no longer supports it)
toolkits_le() {
  local drv=$1 cap=$2; shift 2
  local c
  for c in "$@"; do
    [[ "$c" =~ ^[0-9]+-[0-9]+$ ]] || continue
    [ "$cap" = max12 ] && [ "${c%%-*}" -gt 12 ] && continue
    ver_le "$c" "$drv" && echo "$c"
  done | sort -V -r | tr '\n' ' ' | sed 's/ $//'
}
# CUDA version supported by the driver, from plain nvidia-smi output
parse_driver_cuda() { grep -o 'CUDA Version: *[0-9][0-9.]*' | head -n1 | grep -o '[0-9][0-9.]*$'; }
# max gcc major version a CUDA toolkit accepts (conservative)
max_gcc_for_cuda() {
  local v=${1//-/.}
  if ver_le "$v" "11.9"; then echo 11
  elif ver_le "$v" "12.3"; then echo 12
  elif ver_le "$v" "12.7"; then echo 13
  else echo 14; fi
}
is_wsl2() { grep -qiE 'microsoft-standard|WSL2' "$PROC_VERSION" 2>/dev/null; }
is_wsl1() { grep -qi 'microsoft' "$PROC_VERSION" 2>/dev/null && ! is_wsl2; }

if [ "$SELFTEST" = 1 ]; then
  fails=0
  t() { if [ "$2" = "$3" ]; then echo "PASS  $1: '$2'"; else echo "FAIL  $1: '$2' (verwacht '$3')"; fails=$((fails + 1)); fi; }
  t "choose 12.4 uit 11-8 12-0 12-4 12-6 13-0" "$(choose_toolkit 12.4 11-8 12-0 12-4 12-6 13-0)" "12-4"
  t "choose 12.9 uit 12-6 12-8 12-9 13-0" "$(choose_toolkit 12.9 12-6 12-8 12-9 13-0)" "12-9"
  t "choose 13.2 uit 12-9 13-0 13-1 13-2" "$(choose_toolkit 13.2 12-9 13-0 13-1 13-2)" "13-2"
  t "choose 12.10 uit 12-9 12-10 12-11" "$(choose_toolkit 12.10 12-9 12-10 12-11)" "12-10"
  t "choose 11.4 uit 12-0 12-6 (driver te oud)" "$(choose_toolkit 11.4 12-0 12-6)" ""
  t "choose 12.2 uit 12-0 12-1 12-2 12-3" "$(choose_toolkit 12.2 12-0 12-1 12-2 12-3)" "12-2"
  t "parse nvidia-smi kop" "$(printf '| NVIDIA-SMI 560.35.02   Driver Version: 561.09   CUDA Version: 12.6     |\n' | parse_driver_cuda)" "12.6"
  t "parse nvidia-smi 13.0" "$(printf '| NVIDIA-SMI 580.76.04  Driver Version: 581.08  CUDA Version: 13.0 |\n' | parse_driver_cuda)" "13.0"
  t "max gcc CUDA 12-0" "$(max_gcc_for_cuda 12-0)" "12"
  t "max gcc CUDA 12-6" "$(max_gcc_for_cuda 12-6)" "13"
  t "max gcc CUDA 13-0" "$(max_gcc_for_cuda 13-0)" "14"
  t "ver_le 12.4 12.10" "$(ver_le 12.4 12.10 && echo ja || echo nee)" "ja"
  t "toolkits_le 12.8" "$(toolkits_le 12.8 - 11-8 12-0 12-6 12-8 12-9 13-0)" "12-8 12-6 12-0 11-8"
  t "toolkits_le 13.1 max12 (Ubuntu 20.04)" "$(toolkits_le 13.1 max12 12-4 12-9 13-0 13-1)" "12-9 12-4"
  t "toolkits_le 13.0 met 12-10" "$(toolkits_le 13.0 - 12-9 12-10 13-0 13-2)" "13-0 12-10 12-9"
  tmp=$(mktemp); echo "Linux version 6.6.87.2-microsoft-standard-WSL2 (root@...) #1 SMP" > "$tmp"
  t "WSL2-kernel herkend" "$(PROC_VERSION=$tmp; is_wsl2 && echo wsl2 || echo nee)" "wsl2"
  echo "Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com)" > "$tmp"
  t "WSL1-kernel herkend" "$(PROC_VERSION=$tmp; is_wsl1 && echo wsl1 || echo nee)" "wsl1"
  echo "Linux version 6.8.0-45-generic (buildd@lcy02)" > "$tmp"
  t "gewone Linux" "$(PROC_VERSION=$tmp; is_wsl2 || is_wsl1 || echo linux)" "linux"
  rm -f "$tmp"
  echo "== $fails fout(en) =="
  exit $fails
fi

OWNER=$(stat -c %U "$CEL")
# directories this script creates must belong to the owner of the repository, also when it runs as
# root (wsl -u root): the owner's builds, test runs and later sweeps write into them
mkdir_owner() {
  local d
  for d in "$@"; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d" || return 1
      if [ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ]; then chown "$OWNER": "$d"; fi
    fi
  done
}
LOGDIR=$CEL/runs/_setup
mkdir_owner "$CEL/runs" "$LOGDIR" "$PC_DIR/_build"
LOG=$LOGDIR/setup_$(date +%Y%m%d_%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "Oercel setup — $(date '+%Y-%m-%d %H:%M:%S') — log: $LOG"
[ "$DRY" = 1 ] && echo "DROOG: er wordt niets met root uitgevoerd en niets gedownload"

SUDO=""; NO_ROOT=0; KEEPALIVE=""
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif have sudo && sudo -n true 2>/dev/null; then
  SUDO="sudo"
elif have sudo && [ -t 0 ] && [ "$DRY" != 1 ]; then
  echo "Voor apt en CUDA is root nodig: sudo vraagt nu één keer je wachtwoord."
  if sudo -v; then
    SUDO="sudo"
    ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    KEEPALIVE=$!
  else
    NO_ROOT=1
  fi
else
  NO_ROOT=1
fi
[ "${OERCEL_TEST_NO_ROOT:-0}" = 1 ] && { SUDO=""; NO_ROOT=1; }    # test hook: behave as a user without sudo
if [ -n "${OERCEL_PROC_VERSION:-}${OERCEL_OS_RELEASE:-}" ] && [ "$NO_ROOT" != 1 ] && [ "$DRY" != 1 ]; then
  DRY=1; echo "TESTMODUS (nep-/proc/version of -os-release): automatisch --droog, er wordt niets met root gedaan"
fi
cleanup() {
  [ -n "$KEEPALIVE" ] && kill "$KEEPALIVE" 2>/dev/null
  [ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ] && chown -R "$OWNER": "$LOGDIR" "$PC_DIR/_build" 2>/dev/null
}
trap cleanup EXIT
# apt-get: wait up to 10 min for the dpkg lock instead of failing at once; never a question (debconf, needrestart)
APT=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 -y -q)
# run a command as root (or show it in dry-run / without root)
priv() {
  if [ "$DRY" = 1 ]; then echo "  [droog] $*" >&2; return 0; fi
  if [ "$NO_ROOT" = 1 ]; then echo "  [geen root] zou uitvoeren: $*" >&2; return 99; fi
  $SUDO "$@"
}
# run a command as the owner of the repository (when the script runs as root via wsl -u root)
as_owner() {
  if [ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ]; then
    sudo -u "$OWNER" -H env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

# ------------------------------------------------------------------------------------- 1. omgeving
hdr "1. omgeving"
IS_WSL2=0
if is_wsl2; then
  IS_WSL2=1
  res OK "WSL2" "WSL2-kernel: $(cut -d' ' -f3 "$PROC_VERSION")"
elif is_wsl1; then
  res FOUT "WSL2" "dit is WSL1 (geen GPU-toegang). In PowerShell: wsl --set-version <distro> 2"
else
  res WAARSCHUWING "WSL2" "niet in WSL; ga door als gewone Linux (CUDA-installatie wordt overgeslagen)"
fi
UB_ID=""; UB_VER=""
if [ -r "$OS_RELEASE" ]; then
  UB_ID=$(. "$OS_RELEASE"; echo "${ID:-}"); UB_VER=$(. "$OS_RELEASE"; echo "${VERSION_ID:-}")
fi
if [ "$UB_ID" = "ubuntu" ]; then
  if ver_le "20.04" "$UB_VER"; then res OK "Ubuntu" "Ubuntu $UB_VER"
  else res WAARSCHUWING "Ubuntu" "Ubuntu $UB_VER is oud; 22.04 of 24.04 aanbevolen"; fi
else
  res WAARSCHUWING "Ubuntu" "distributie '${UB_ID:-?} ${UB_VER}' — dit script is gemaakt voor Ubuntu"
fi
ARCH=$(uname -m)
case "$CEL" in
  /mnt/[a-zA-Z]/*)
    res WAARSCHUWING "repo-locatie" "$REPO staat op de Windows-schijf (/mnt/...): bestanden zijn daar ~10x trager"
    info "Verplaats de repo naar je Linux-thuismap en draai dit script daar opnieuw:"
    url=$(git -C "$REPO" remote get-url origin 2>/dev/null || echo "<github-url>")
    br=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "<branch>")
    info "    cd ~ && git clone -b $br $url && bash ~/$(basename "$REPO")/cel/pc/setup_wsl.sh"
    info "  (of kopiëren: cp -a \"$REPO\" ~/ )" ;;
  *) res OK "repo-locatie" "$REPO (Linux-bestandssysteem)" ;;
esac
NCPU=$(nproc)
MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
FREE_GB=$(df -P "$CEL" | awk 'NR==2 {printf "%.0f", $4/1048576}')
info "CPU: $NCPU logische kernen ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')), geheugen $MEM_GB GB, vrij op schijf $FREE_GB GB"
if grep -q avx512f /proc/cpuinfo; then AVX="AVX-512 (snelle kernel)"; else AVX="geen AVX-512: de engine gebruikt de scalaire kernel (getest, ~1,7x trager per kern)"; fi
info "CPU-vectoreenheden: $AVX"
[ "$IS_WSL2" = 1 ] && [ "$MEM_GB" -lt 32 ] && info "Tip: WSL2 krijgt standaard de helft van het Windows-geheugen; meer via %UserProfile%\\.wslconfig ([wsl2] memory=96GB)"
[ "${FREE_GB:-0}" -lt 50 ] && res WAARSCHUWING "schijf" "maar $FREE_GB GB vrij; lange runs hebben tientallen GB nodig"
if [ "$IS_WSL2" = 1 ] && [ -d /mnt/c ]; then
  # the virtual Linux disk (ext4.vhdx) grows on the Windows drive, normally C:; df above shows the virtual disk
  CFREE_GB=$(df -P /mnt/c 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')
  info "Windows-schijf C: ${CFREE_GB:-?} GB vrij (daarop groeit de virtuele WSL-schijf; de run-scripts pauzeren onder 10 GB)"
  [ -n "$CFREE_GB" ] && [ "$CFREE_GB" -lt 50 ] && res WAARSCHUWING "Windows C:" "maar $CFREE_GB GB vrij op C:; snapshots van lange runs komen (via de virtuele WSL-schijf) op C: terecht"
  info "Tip: in PowerShell 'wsl --manage ${WSL_DISTRO_NAME:-<distro>} --set-sparse true' laat WSL vrijgekomen ruimte aan Windows teruggeven"
fi
if [ "$NO_ROOT" = 1 ] && [ "$DRY" != 1 ]; then
  res WAARSCHUWING "root" "geen root/sudo zonder wachtwoord: apt en CUDA worden alleen gecontroleerd"
fi

# ------------------------------------------------------------------------------------- 2. apt
hdr "2. pakketten (apt)"
# an earlier run that was interrupted (window closed, wsl --shutdown) can leave dpkg half-way: repair first
if [ "$DO_APT" = 1 ] && [ "$DRY" != 1 ] && [ "$NO_ROOT" != 1 ] && [ -n "$(dpkg --audit 2>/dev/null)" ]; then
  info "dpkg was niet klaar (onderbroken installatie?): dpkg --configure -a"
  priv env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || info "dpkg --configure -a gaf een fout (zie log)"
  priv "${APT[@]}" install -f || true
fi
PKGS=(build-essential make gcc g++ python3 python3-venv python3-pip python3-numpy python3-scipy
      python3-matplotlib python3-pandas python3-pil python3-yaml ffmpeg fonts-dejavu-core
      wget curl ca-certificates gnupg git procps tmux)    # curl + tmux: start.sh (Claude Code, Remote Control)
PYCHECK='import sys, numpy, scipy, matplotlib, pandas, PIL
matplotlib.use("Agg")
import matplotlib.pyplot
from scipy.spatial import cKDTree, ConvexHull, QhullError
from scipy import fft, ndimage, stats
from scipy.sparse.csgraph import connected_components, breadth_first_order
from PIL import Image, ImageDraw, ImageFilter, ImageFont
print(f"Python {sys.version.split()[0]}, numpy {numpy.__version__}, scipy {scipy.__version__}, matplotlib {matplotlib.__version__}, pandas {pandas.__version__}, Pillow {PIL.__version__}")'
missing=()
PY_OK=0; have python3 && python3 -c "$PYCHECK" >/dev/null 2>&1 && PY_OK=1
for p in "${PKGS[@]}"; do
  # the Python packages are not needed when python3 already imports everything (installed another way);
  # python3-venv stays: the venv fallback needs it when the tools turn out to need newer versions
  [ "$PY_OK" = 1 ] && [[ "$p" == python3-* ]] && [ "$p" != python3-venv ] && continue
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
done
if [ ${#missing[@]} -eq 0 ]; then
  res OK "apt-pakketten" "alle ${#PKGS[@]} pakketten aanwezig"
elif [ "$DO_APT" = 0 ]; then
  res WAARSCHUWING "apt-pakketten" "ontbreken (niet geïnstalleerd door --geen-apt): ${missing[*]}"
else
  info "installeren: ${missing[*]}"
  priv "${APT[@]}" update || info "apt-get update gaf een fout (zie log); installeren wordt toch geprobeerd"
  if priv "${APT[@]}" install --no-install-recommends "${missing[@]}"; then
    [ "$DRY" = 1 ] && res OVERGESLAGEN "apt-pakketten" "droog: ${#missing[@]} pakketten zouden worden geïnstalleerd" \
                   || res OK "apt-pakketten" "${#missing[@]} pakketten geïnstalleerd"
  else
    res FOUT "apt-pakketten" "installatie niet gelukt (root nodig?): ${missing[*]}"
  fi
fi

# ------------------------------------------------------------------------------------- 2b. GitHub CLI
# The repository is cloned anonymously (https), so git cannot push.  start.sh logs in once with
# 'gh auth login' and makes git use gh for github.com ('gh auth setup-git'); the token stays in ~/.config/gh.
# Source: GitHub's official apt repository, exactly as "Recommended (Official)" in
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md (keyring in /etc/apt/keyrings, list in
# /etc/apt/sources.list.d/github-cli.list).  Ubuntu's own package 'gh' is only the fallback when that repository
# cannot be used: it is old (22.04: 2.4.0, 24.04: 2.45.0, 20.04: none), and the same document says (since Nov 2025)
# that the community 2.45.x/2.46.x packages are broken by deprecated GitHub APIs.  Logging in and pushing work
# with them, so an old gh that cannot be upgraded is only a warning.
hdr "2b. GitHub CLI (gh)"
GH_PKGS=https://cli.github.com/packages
GH_KEYRING=/etc/apt/keyrings/githubcli-archive-keyring.gpg
GH_LIST=/etc/apt/sources.list.d/github-cli.list
GH_MIN=2.47        # older: Ubuntu's/Debian's community package -> upgrade through GitHub's repository
have_gh() { [ -n "${OERCEL_TEST_GH_VERSION:-}" ] || { [ "${OERCEL_TEST_NO_GH:-0}" != 1 ] && have gh; }; }   # test hooks
gh_ver() {
  if [ -n "${OERCEL_TEST_GH_VERSION:-}" ]; then echo "$OERCEL_TEST_GH_VERSION"; return; fi
  gh --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}
gh_candidate() {     # version apt would install, empty when none
  local c
  if [ -n "${OERCEL_TEST_GH_CANDIDATE:-}" ]; then c=$OERCEL_TEST_GH_CANDIDATE     # test hook ("none" = no package)
  else c=$(apt-cache policy gh 2>/dev/null | awk '/Candidate:/ {print $2; exit}'); fi
  case "$c" in ""|"(none)"|none) return 0 ;; *) printf '%s' "$c" ;; esac
}
gh_official_repo() {
  local arch tmp
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  info "GitHubs officiële apt-repository: $GH_PKGS (sleutel: $GH_KEYRING)"
  if [ "${OERCEL_TEST_GH_REPO_FAIL:-0}" = 1 ]; then info "[test] GitHubs repository niet bereikbaar"; return 1; fi
  if [ "$DRY" = 1 ]; then
    echo "  [droog] wget -nv -O \$tmp $GH_PKGS/githubcli-archive-keyring.gpg && tee $GH_KEYRING && chmod go+r $GH_KEYRING" >&2
    echo "  [droog] $GH_LIST: deb [arch=$arch signed-by=$GH_KEYRING] $GH_PKGS stable main" >&2
    priv "${APT[@]}" update; priv "${APT[@]}" install gh
    return
  fi
  if [ "$NO_ROOT" = 1 ]; then echo "  [geen root] zou GitHubs apt-repository toevoegen en gh installeren" >&2; return 99; fi
  tmp=$(mktemp) || return 1
  if ! { wget -nv -O "$tmp" "$GH_PKGS/githubcli-archive-keyring.gpg" || curl -fsSL -o "$tmp" "$GH_PKGS/githubcli-archive-keyring.gpg"; } \
     || [ ! -s "$tmp" ]; then
    rm -f "$tmp"; info "download van de sleutel mislukt ($GH_PKGS): internet/proxy?"; return 1
  fi
  priv mkdir -p -m 755 /etc/apt/keyrings && priv tee "$GH_KEYRING" < "$tmp" >/dev/null && priv chmod go+r "$GH_KEYRING" \
    || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  priv mkdir -p -m 755 /etc/apt/sources.list.d && \
    echo "deb [arch=$arch signed-by=$GH_KEYRING] $GH_PKGS stable main" | priv tee "$GH_LIST" >/dev/null || return 1
  priv "${APT[@]}" update >/dev/null || info "apt-get update gaf een fout (zie log)"
  # only when apt really sees GitHub's repository (else 'install gh' would quietly take Ubuntu's old package);
  # never leave an unreachable repository behind: every later apt-get update would complain about it
  if ! apt-cache policy gh 2>/dev/null | grep -q 'cli\.github\.com'; then
    info "apt ziet GitHubs repository niet (cli.github.com niet bereikbaar?)"; priv rm -f "$GH_LIST"; return 1
  fi
  priv "${APT[@]}" install gh || { priv rm -f "$GH_LIST"; return 1; }
}
GH_NOW=""; have_gh && GH_NOW=$(gh_ver)
if [ -n "$GH_NOW" ] && ver_le "$GH_MIN" "$GH_NOW"; then
  res OK "GitHub CLI" "al aanwezig: gh $GH_NOW"
elif [ "$DO_APT" = 0 ]; then
  if have_gh; then res WAARSCHUWING "GitHub CLI" "gh ${GH_NOW:-?} is oud (niet bijgewerkt door --geen-apt); inloggen en pushen werken wel"
  else res WAARSCHUWING "GitHub CLI" "gh ontbreekt (niet geïnstalleerd door --geen-apt); zonder gh kan Claude niet naar GitHub pushen"; fi
else
  [ -n "$GH_NOW" ] && info "gh $GH_NOW is oud (Ubuntu-pakket?): bijwerken via GitHubs officiële repository"
  GH_HOW=""
  if gh_official_repo; then
    GH_HOW="GitHubs officiële repository"
  elif ! have_gh; then
    GHC=$(gh_candidate)
    if [ -z "$GHC" ] && [ "$DRY" != 1 ] && [ "$NO_ROOT" != 1 ]; then
      priv "${APT[@]}" update >/dev/null 2>&1; GHC=$(gh_candidate)      # package lists may be old
    fi
    if [ -n "$GHC" ]; then
      info "terugval: Ubuntu's eigen pakket gh $GHC (oud, maar inloggen en pushen werken)"
      priv "${APT[@]}" install --no-install-recommends gh && GH_HOW="Ubuntu-pakket $GHC, terugval"
    else
      info "Ubuntu ${UB_VER:-?} heeft geen pakket 'gh'"
    fi
  fi
  if [ "$DRY" = 1 ]; then res OVERGESLAGEN "GitHub CLI" "droog: gh zou worden geïnstalleerd (${GH_HOW:-?})"
  elif have_gh && [ -n "$GH_HOW" ]; then res OK "GitHub CLI" "geïnstalleerd ($GH_HOW): gh $(gh_ver)"
  elif have_gh; then
    res WAARSCHUWING "GitHub CLI" "gh $(gh_ver) is oud en bijwerken via GitHubs repository lukte niet (internet/root?); inloggen en pushen werken wel"
  else
    # not fatal: everything runs without it, only pushing to GitHub does not (start.sh says so)
    res WAARSCHUWING "GitHub CLI" "gh niet geïnstalleerd (root/internet?); Claude kan dan niet naar GitHub pushen. Later: bash cel/pc/setup_wsl.sh --geen-tests"
  fi
fi

# ------------------------------------------------------------------------------------- 3. python
hdr "3. Python voor analyse en beelden"
TOOLS_PY=""
VENV=$PC_DIR/.venv
# venv with current numpy/scipy/matplotlib/pandas/pillow from PyPI (when the apt versions do not work)
make_venv() {
  info "venv maken in $VENV (pip install numpy scipy matplotlib pandas pillow pyyaml)"
  [ "$DRY" = 1 ] && { echo "  [droog] python3 -m venv $VENV && pip install ..." >&2; return 1; }
  as_owner python3 -m venv "$VENV" && as_owner "$VENV/bin/pip" install -q --upgrade pip && \
    as_owner "$VENV/bin/pip" install -q numpy scipy matplotlib pandas pillow pyyaml && \
    "$VENV/bin/python" -c "$PYCHECK" >/dev/null 2>&1
}
# make plain `python3` in new shells (also Claude Code's) find the venv
venv_in_bashrc() {
  export PATH="$VENV/bin:$PATH"
  if ! grep -q "oercel-pc-env" "$(eval echo ~"$OWNER")/.bashrc" 2>/dev/null; then
    if [ "$DRY" = 1 ]; then echo "  [droog] regel toevoegen aan ~/.bashrc: source $PC_DIR/env.sh"
    else
      as_owner bash -c "printf '\n[ -f \"%s\" ] && . \"%s\"  # oercel-pc-env\n' '$PC_DIR/env.sh' '$PC_DIR/env.sh' >> ~/.bashrc"
      info "\$HOME/.bashrc laadt nu $PC_DIR/env.sh (venv vooraan in PATH)"
    fi
  fi
}
if [ -x "$VENV/bin/python" ] && ! "$VENV/bin/python" -c "$PYCHECK" >/dev/null 2>&1 && [ "$DRY" != 1 ]; then
  # a venv from an earlier (interrupted?) run that does not work: the pc scripts would use it (pclib.tools_python)
  info "bestaande venv $VENV werkt niet: repareren"
  if ! make_venv; then
    mv "$VENV" "$VENV.kapot.$(date +%Y%m%d_%H%M%S)" && info "kapotte venv opzij gezet; de systeem-Python wordt geprobeerd"
  fi
fi
if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "$PYCHECK" >/dev/null 2>&1; then
  TOOLS_PY=$VENV/bin/python
  res OK "python" "venv $VENV: $("$VENV/bin/python" -c "$PYCHECK" 2>&1 | tail -1)"
elif have python3 && python3 -c "$PYCHECK" >/dev/null 2>&1; then
  TOOLS_PY=$(command -v python3)
  res OK "python" "systeem-python3: $(python3 -c "$PYCHECK" 2>&1 | tail -1)"
elif have python3; then
  info "systeem-python3 mist iets: $(python3 -c "$PYCHECK" 2>&1 | tail -1)"
  if [ "$DRY" = 1 ]; then
    make_venv; res OVERGESLAGEN "python" "droog: venv zou worden gemaakt"
  elif make_venv; then
    TOOLS_PY=$VENV/bin/python
    res OK "python" "venv gemaakt: $("$VENV/bin/python" -c "$PYCHECK" 2>&1 | tail -1)"
  else
    res FOUT "python" "geen werkende Python-omgeving (python3-venv geïnstalleerd? internet naar PyPI?)"
  fi
else
  res FOUT "python" "python3 ontbreekt"
fi
if [ -n "$TOOLS_PY" ] && [ "$TOOLS_PY" = "$VENV/bin/python" ]; then
  venv_in_bashrc
fi
FFOK=0; have ffmpeg && [ "${OERCEL_TEST_NO_FFMPEG:-0}" != 1 ] && FFOK=1     # test hook: pretend ffmpeg is missing
[ $FFOK = 1 ] && res OK "ffmpeg" "$(ffmpeg -version 2>/dev/null | head -n1 | cut -d' ' -f1-3)" || res WAARSCHUWING "ffmpeg" "ontbreekt (alleen nodig voor MP4-video's)"

# ------------------------------------------------------------------------------------- 4. CUDA
hdr "4. GPU en CUDA-toolkit"
GPU_OK=0; NVCC=""; DRV_CUDA=""
SMI=$(command -v nvidia-smi 2>/dev/null || true)
[ -z "$SMI" ] && [ -x /usr/lib/wsl/lib/nvidia-smi ] && SMI=/usr/lib/wsl/lib/nvidia-smi
find_nvcc() {
  NVCC=""
  [ "${OERCEL_TEST_NO_NVCC:-0}" = 1 ] && return 1     # test hook: pretend no toolkit is installed
  for c in /usr/local/cuda/bin/nvcc $(ls -d /usr/local/cuda-*/bin/nvcc 2>/dev/null | sort -V -r) $(command -v nvcc 2>/dev/null) \
           "$CEL/engine_gpu/.cuda/bin/nvcc"; do
    [ -x "$c" ] && "$c" --version >/dev/null 2>&1 && { NVCC=$c; return 0; }   # skips a dangling wrapper
  done
  return 1
}
nvcc_ver() { "$1" --version 2>/dev/null | grep -o 'release [0-9.]*' | awk '{print $2}'; }
dpkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
# install toolkit X-Y: the full cuda-toolkit-X-Y (NVIDIA's WSL instruction).  If apt cannot (e.g. the tools
# of an older toolkit need a library a newer Ubuntu no longer has), only what oercel_gpu needs:
# compiler + runtime + headers.  Never the metapackages cuda / cuda-X / cuda-drivers.
install_toolkit() {
  local tk=$1 p
  local min=()
  info "installeren: cuda-toolkit-$tk (alleen de toolkit, géén driver)"
  if priv "${APT[@]}" install --no-install-recommends "cuda-toolkit-$tk"; then TK_MODE=volledig; return 0; fi
  [ "$DRY" = 1 ] && return 1
  for p in "cuda-nvcc-$tk" "cuda-cudart-dev-$tk" "cuda-cccl-$tk"; do
    apt-cache show "$p" >/dev/null 2>&1 && min+=("$p")
  done
  [ ${#min[@]} -ge 2 ] || return 1
  info "cuda-toolkit-$tk lukt niet; dan alleen compiler + runtime: ${min[*]}"
  priv "${APT[@]}" install --no-install-recommends "${min[@]}" && TK_MODE=minimaal
}
DRV_PKGS() { dpkg-query -W -f='${binary:Package} ${Status}\n' 'nvidia-driver-*' 'cuda-drivers*' 'nvidia-dkms-*' 'libnvidia-compute-*' 'nvidia-utils-*' 2>/dev/null | awk '/install ok installed/ {print $1}'; }

if [ "$DO_CUDA" = 0 ]; then
  res OVERGESLAGEN "CUDA" "--geen-cuda"
elif [ "$ARCH" != "x86_64" ]; then
  res OVERGESLAGEN "CUDA" "architectuur $ARCH (alleen x86_64 ondersteund door dit script)"
elif [ -z "$SMI" ] || ! "$SMI" >/dev/null 2>&1; then
  if [ "$IS_WSL2" = 1 ]; then
    res FOUT "GPU" "nvidia-smi werkt niet in WSL2. Installeer/actualiseer de NVIDIA-driver in WINDOWS (nvidia.com/drivers, Quadro RTX 8000), daarna in PowerShell: wsl --shutdown, en dit script opnieuw. Installeer GEEN driver in Ubuntu."
  else
    res OVERGESLAGEN "GPU" "geen werkende nvidia-smi (geen GPU of geen driver); alleen CPU"
  fi
else
  GPU_OK=1
  SMI_OUT=$("$SMI" 2>/dev/null)
  DRV_CUDA=$(printf '%s\n' "$SMI_OUT" | parse_driver_cuda)
  GPUQ=$("$SMI" --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -n1)
  CC=$("$SMI" --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1)
  res OK "GPU" "$GPUQ${CC:+, compute capability $CC}; driver ondersteunt CUDA ${DRV_CUDA:-?}"
  bad=$(DRV_PKGS); BAD_BEFORE=$bad
  if [ -n "$bad" ] && [ "$IS_WSL2" = 1 ]; then
    res FOUT "Linux-driver" "in WSL2 mag geen Linux-NVIDIA-driver staan, gevonden: $(echo $bad). Verwijderen met: sudo apt-get remove --purge $(echo $bad)"
  fi
  if find_nvcc; then
    NV=$(nvcc_ver "$NVCC"); NVD=${NV/./-}
    if [ "$IS_WSL2" = 1 ] && dpkg_ok "cuda-nvcc-$NVD" && ! dpkg_ok "cuda-cudart-dev-$NVD" && ! dpkg_ok "cuda-toolkit-$NVD"; then
      # nvcc came from apt but the rest is missing: an earlier installation was interrupted
      info "CUDA $NV is maar half geïnstalleerd (onderbroken?): aanvullen"
      if [ "$NO_ROOT" = 1 ] && [ "$DRY" != 1 ]; then res FOUT "CUDA-toolkit" "CUDA $NV half geïnstalleerd; aanvullen vraagt root (zie onderaan)"
      elif install_toolkit "$NVD"; then res OK "CUDA-toolkit" "CUDA $NV aangevuld ($TK_MODE): $NVCC"
      else res FOUT "CUDA-toolkit" "aanvullen van CUDA $NV mislukt (zie log)"; fi
    elif [ -n "$DRV_CUDA" ] && ! ver_le "$NV" "$DRV_CUDA"; then
      res WAARSCHUWING "CUDA-toolkit" "$NVCC is CUDA $NV, nieuwer dan wat de driver aankan ($DRV_CUDA): update de Windows-driver of installeer --cuda-versie ${DRV_CUDA/./-}"
    else
      res OK "CUDA-toolkit" "al aanwezig: $NVCC (CUDA $NV)"
    fi
  elif [ "$IS_WSL2" != 1 ]; then
    res OVERGESLAGEN "CUDA-toolkit" "geen WSL2: installeer de toolkit zelf (NVIDIA-repo voor jouw distributie)"
  else
    # --- install the toolkit from NVIDIA's WSL-Ubuntu repository
    ok=1
    PIN_TEXT="# Oercel (cel/pc/setup_wsl.sh): in WSL2 levert de WINDOWS-driver de GPU.
# Een Linux-NVIDIA-driver in WSL breekt de GPU-toegang, dus die pakketten worden hier geblokkeerd.
Package: cuda-drivers* nvidia-driver-* nvidia-dkms-* nvidia-kernel-* nvidia-open* libnvidia-compute-* nvidia-utils-* xserver-xorg-video-nvidia-* nvidia-headless-*
Pin: version *
Pin-Priority: -1"
    if [ "$NO_ROOT" = 1 ] && [ "$DRY" != 1 ]; then
      ok=0
      res FOUT "CUDA-toolkit" "niet geïnstalleerd: hiervoor is root nodig (zie onderaan)"
    fi
    if [ $ok = 1 ] && [ ! -f "$PIN_FILE" ]; then
      info "apt-pin tegen Linux-NVIDIA-drivers: $PIN_FILE"
      if [ "$DRY" = 1 ]; then printf '  [droog] %s:\n%s\n' "$PIN_FILE" "$PIN_TEXT"
      else printf '%s\n' "$PIN_TEXT" | priv tee "$PIN_FILE" >/dev/null || ok=0; fi
    fi
    if [ $ok = 1 ] && ! grep -rqs "repos/wsl-ubuntu" /etc/apt/sources.list.d/ /etc/apt/sources.list; then
      TMPD=$(mktemp -d)
      URL=$NVIDIA_REPO/wsl-ubuntu/x86_64/$KEYRING_DEB
      info "NVIDIA WSL-Ubuntu-repository toevoegen: $URL"
      if [ "$DRY" = 1 ]; then
        echo "  [droog] wget $URL && dpkg -i $KEYRING_DEB"
      elif wget -q -O "$TMPD/$KEYRING_DEB" "$URL"; then
        priv dpkg -i "$TMPD/$KEYRING_DEB" || ok=0
      else
        UV=${UB_VER//./}
        URL2=$NVIDIA_REPO/ubuntu$UV/x86_64/$KEYRING_DEB
        info "WSL-repository niet bereikbaar; terugval op de gewone Ubuntu $UB_VER-repository (alleen de toolkit, drivers geblokkeerd): $URL2"
        if wget -q -O "$TMPD/$KEYRING_DEB" "$URL2"; then priv dpkg -i "$TMPD/$KEYRING_DEB" || ok=0
        else ok=0; res FOUT "CUDA-toolkit" "download van de NVIDIA-repository mislukt ($URL en $URL2): internet/proxy?"; fi
      fi
      rm -rf "$TMPD"
    fi
    if [ $ok = 1 ]; then
      # remove the outdated NVIDIA signing key if an old setup left it (NVIDIA's own instruction)
      if have apt-key && apt-key list 2>/dev/null | grep -q "7FA2 AF80"; then priv apt-key del 7fa2af80 >/dev/null 2>&1; fi
      priv "${APT[@]}" update >/dev/null || info "apt-get update gaf een fout (zie log)"
      CANDS=$(apt-cache pkgnames cuda-toolkit- 2>/dev/null | grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' | sed 's/^cuda-toolkit-//' | sort -V | tr '\n' ' ')
      info "beschikbare toolkits: ${CANDS:-(geen gevonden)}"
      CAP=-
      if [ "$UB_ID" = ubuntu ] && ver_le "$UB_VER" "20.04"; then CAP=max12; info "Ubuntu $UB_VER: alleen CUDA 12.x of ouder (CUDA 13 ondersteunt 20.04 niet)"; fi
      if [ -n "$CUDA_WANT" ]; then TKS=$CUDA_WANT
      else TKS=$(toolkits_le "${DRV_CUDA:-0}" "$CAP" $CANDS | cut -d' ' -f1-3); fi
      if [ "$DRY" = 1 ] && [ -z "$TKS" ]; then
        if [ "$CAP" = max12 ] && [ "${DRV_CUDA%%.*}" -gt 12 ]; then TKS=12-x; else TKS=${DRV_CUDA/./-}; fi
        info "droog: repository niet echt toegevoegd; zou kiezen: cuda-toolkit-$TKS (= driver-versie of lager)"
      fi
      if [ -z "$TKS" ]; then
        if [ -z "$CANDS" ]; then res FOUT "CUDA-toolkit" "de NVIDIA-repository levert geen cuda-toolkit-pakketten (apt-get update mislukt?)"
        else res FOUT "CUDA-toolkit" "geen toolkit-versie <= CUDA $DRV_CUDA (wat de driver aankan) in: $CANDS — update de Windows-driver"; fi
      else
        TK=""; TK_MODE=""
        for t in $TKS; do         # newest first; an older one when apt cannot install the newest
          if install_toolkit "$t"; then TK=$t; break; fi
          info "cuda-toolkit-$t lukt niet; volgende kandidaat"
        done
        if [ -z "$TK" ]; then
          res FOUT "CUDA-toolkit" "apt-get install mislukt voor: $TKS (zie log)"
        elif [ "$DRY" = 1 ]; then res OVERGESLAGEN "CUDA-toolkit" "droog: cuda-toolkit-$TK zou worden geïnstalleerd"
        else
          find_nvcc && res OK "CUDA-toolkit" "CUDA $TK geïnstalleerd ($TK_MODE): $NVCC" || res FOUT "CUDA-toolkit" "installatie gaf geen nvcc"
        fi
        bad=$(comm -13 <(echo "$BAD_BEFORE" | sort) <(DRV_PKGS | sort) | tr '\n' ' ')
        [ -n "${bad// /}" ] && res FOUT "Linux-driver" "er is toch een Linux-driver binnengekomen: $(echo $bad) — verwijder met: sudo apt-get remove --purge $(echo $bad)"
      fi
    elif [ "$NO_ROOT" != 1 ]; then
      res FOUT "CUDA-toolkit" "niet geïnstalleerd: de NVIDIA-repository kon niet worden toegevoegd (zie boven)"
    fi
  fi
fi

# no system toolkit (no root, download failed): the GPU engine's own setup can fetch nvcc WITHOUT root
# from NVIDIA's redistributable archives into engine_gpu/.cuda (and builds oercel_gpu)
downgrade() { local i; for i in "${!R_NAME[@]}"; do [ "${R_NAME[$i]}" = "$1" ] && [ "${R_STAT[$i]}" = FOUT ] && R_STAT[$i]=WAARSCHUWING; done; }
if [ "$GPU_OK" = 1 ] && [ "$DO_CUDA" = 1 ] && ! find_nvcc && [ -f "$CEL/engine_gpu/setup_wsl.sh" ]; then
  if [ "$DRY" = 1 ]; then
    echo "  [droog] terugval: bash engine_gpu/setup_wsl.sh (nvcc zonder root naar engine_gpu/.cuda)" >&2
  else
    info "terugval: engine_gpu/setup_wsl.sh haalt nvcc zonder root naar engine_gpu/.cuda ..."
    if as_owner bash "$CEL/engine_gpu/setup_wsl.sh" > "$LOGDIR/engine_gpu_setup.log" 2>&1 && find_nvcc; then
      downgrade "CUDA-toolkit"
      res OK "CUDA-toolkit" "lokale nvcc (zonder root) via engine_gpu/setup_wsl.sh: $NVCC"
    else
      res FOUT "CUDA-terugval" "engine_gpu/setup_wsl.sh lukte ook niet (log: $LOGDIR/engine_gpu_setup.log)"
    fi
  fi
fi

# PATH for nvcc, host-compiler check and the end-to-end CUDA test
NVCC_CCBIN=""
if [ "$GPU_OK" = 1 ] && find_nvcc; then
  CUDA_BIN=$(dirname "$NVCC")
  export PATH="$CUDA_BIN:$PATH"
  NV=$(nvcc_ver "$NVCC")
  mkdir_owner "$PC_DIR/_build"
  rm -f "$PC_DIR/_build/cuda_check"    # never run a binary left over from an earlier attempt
  build_check() { as_owner "$NVCC" ${NVCC_CCBIN:+-ccbin "$NVCC_CCBIN"} -O2 -gencode "arch=compute_75,code=[sm_75,compute_75]" \
                    -o "$PC_DIR/_build/cuda_check" "$PC_DIR/cuda_check.cu" > "$PC_DIR/_build/cuda_check.log" 2>&1; }
  if ! build_check; then
    if grep -qi "unsupported GNU version\|unsupported.*gcc\|host compiler" "$PC_DIR/_build/cuda_check.log"; then
      GMAX=$(max_gcc_for_cuda "$NV")
      info "nvcc $NV accepteert gcc $(gcc -dumpversion) niet; probeer g++-$GMAX en lager"
      for g in $(seq "$GMAX" -1 9); do
        have "g++-$g" || priv "${APT[@]}" install --no-install-recommends "g++-$g" >/dev/null 2>&1 || true
        if have "g++-$g"; then
          NVCC_CCBIN=$(command -v "g++-$g")
          build_check && { info "host-compiler voor nvcc: g++-$g (engine_gpu wordt gebouwd met CCBIN=$NVCC_CCBIN)"; break; }
          NVCC_CCBIN=""
        fi
      done
    fi
  fi
  if [ -x "$PC_DIR/_build/cuda_check" ] && [ "$PC_DIR/_build/cuda_check" -nt "$PC_DIR/cuda_check.cu" ]; then
    out=$("$PC_DIR/_build/cuda_check" 2>&1)
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep -q "CUDA OK"; then res OK "CUDA-test" "kernel gecompileerd voor sm_75 en goed uitgevoerd op de GPU"
    else res FOUT "CUDA-test" "test-kernel faalt: $(echo "$out" | tail -n1)"; fi
  else
    res FOUT "CUDA-test" "compileren van pc/cuda_check.cu mislukt: $(tail -n3 "$PC_DIR/_build/cuda_check.log" | tr '\n' ' ')"
  fi
  # make the system toolkit's nvcc available in every new shell (a local engine_gpu/.cuda stays local)
  case "$CUDA_BIN" in
    /usr/local/cuda*)
      PROFILE_TEXT="# Oercel (cel/pc/setup_wsl.sh): CUDA-toolkit in PATH
case \":\$PATH:\" in *:$CUDA_BIN:*) ;; *) export PATH=$CUDA_BIN:\$PATH ;; esac"
      if [ "$(cat "$PROFILE_FILE" 2>/dev/null)" != "$PROFILE_TEXT" ]; then
        printf '%s\n' "$PROFILE_TEXT" | priv tee "$PROFILE_FILE" >/dev/null && info "PATH voor nieuwe shells: $PROFILE_FILE"
      fi
      other=$(env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -c 'command -v nvcc' 2>/dev/null)
      if [ -n "$other" ] && [ "$other" != "/usr/local/bin/nvcc" ] && [ "$(readlink -f "$other")" != "$(readlink -f "$NVCC")" ]; then
        res WAARSCHUWING "nvcc" "er staat nog een andere nvcc in PATH ($other, CUDA $(nvcc_ver "$other")); gebruikt wordt $NVCC via $PROFILE_FILE"
      fi
      if [ -z "$other" ]; then
        printf '#!/bin/sh\n# Oercel (cel/pc/setup_wsl.sh): nvcc ook zonder /usr/local/cuda/bin in PATH\nexec %s "$@"\n' "$NVCC" \
          | priv tee /usr/local/bin/nvcc >/dev/null && priv chmod 755 /usr/local/bin/nvcc && info "/usr/local/bin/nvcc -> $NVCC"
      fi ;;
  esac
fi

# ------------------------------------------------------------------------------------- 5. bouwen
hdr "5. engines bouwen"
if as_owner make -C "$CEL/engine" oercel > "$LOGDIR/build_cpu.log" 2>&1 && "$CEL/engine/oercel" --params >/dev/null 2>&1; then
  res OK "CPU-engine" "engine/oercel gebouwd ($AVX)"
else
  res FOUT "CPU-engine" "bouwen mislukt: $(tail -n3 "$LOGDIR/build_cpu.log" | tr '\n' ' ')"
fi
GPU_ENGINE=0
if [ -f "$CEL/engine_gpu/Makefile" ]; then
  if [ -n "${NVCC:-}" ] || find_nvcc; then
    if as_owner make -C "$CEL/engine_gpu" NVCC="$NVCC" ${NVCC_CCBIN:+CCBIN="$NVCC_CCBIN"} oercel_gpu > "$LOGDIR/build_gpu.log" 2>&1 \
       && [ -x "$CEL/engine_gpu/oercel_gpu" ]; then
      GPU_ENGINE=1
      res OK "GPU-engine" "engine_gpu/oercel_gpu gebouwd met $NVCC (CUDA $(nvcc_ver "$NVCC"))"
    else
      res FOUT "GPU-engine" "bouwen mislukt: $(tail -n3 "$LOGDIR/build_gpu.log" | tr '\n' ' ') (log: $LOGDIR/build_gpu.log)"
    fi
  else
    res OVERGESLAGEN "GPU-engine" "geen nvcc (CUDA-toolkit ontbreekt)"
  fi
  [ "$GPU_OK" = 1 ] || GPU_ENGINE=0
else
  res OVERGESLAGEN "GPU-engine" "map engine_gpu/ (of zijn Makefile) bestaat nog niet"
fi

# ------------------------------------------------------------------------------------- 6. tests
hdr "6. tests"
if [ "$DO_TESTS" = 1 ] && [ -x "$CEL/engine/oercel" ] && [ -n "$TOOLS_PY" ]; then
  info "proefrun: kleine soep -> analyse -> microscoopbeeld ..."
  S=$LOGDIR/proefrun
  proefrun() {
    rm -rf "$S" "$LOGDIR/proefrun_micro.png"
    as_owner "$CEL/engine/oercel" "$CEL/notes/membranen/teamA_membranes.ini" "$S" L=32 steps=4000 snap_every=1000 \
       ckpt_every=2000 log_every=0 threads=2 > "$LOGDIR/proefrun.log" 2>&1 && \
    as_owner "$TOOLS_PY" "$CEL/tools/analyze.py" "$S" --jobs 1 --quiet >> "$LOGDIR/proefrun.log" 2>&1 && \
    as_owner "$TOOLS_PY" "$CEL/tools/render.py" "$S" --kind micro --width 600 --out "$LOGDIR/proefrun_micro.png" >> "$LOGDIR/proefrun.log" 2>&1 && \
    [ -s "$LOGDIR/proefrun_micro.png" ]
  }
  if proefrun; then
    res OK "proefrun" "engine + tools/analyze.py + tools/render.py werken ($LOGDIR/proefrun_micro.png)"
  elif [ "$TOOLS_PY" != "$VENV/bin/python" ] && grep -q "Traceback\|Error" "$LOGDIR/proefrun.log" && make_venv; then
    # the apt Python stack imports fine but is too old for the tools: use a venv with current versions
    info "de tools faalden met de systeem-Python ($(grep -m1 'Error' "$LOGDIR/proefrun.log")); opnieuw met een venv"
    TOOLS_PY=$VENV/bin/python
    venv_in_bashrc
    if proefrun; then res OK "proefrun" "werkt met de venv $VENV (de systeem-Python was te oud)"
    else res FOUT "proefrun" "mislukt, ook met venv: $(tail -n3 "$LOGDIR/proefrun.log" | tr '\n' ' ')"; fi
  else
    res FOUT "proefrun" "mislukt: $(tail -n3 "$LOGDIR/proefrun.log" | tr '\n' ' ')"
  fi
  if [ "$GPU_ENGINE" = 1 ]; then
    G=$LOGDIR/proefrun_gpu
    rm -rf "$G"
    if as_owner "$CEL/engine_gpu/oercel_gpu" "$CEL/notes/membranen/teamA_membranes.ini" "$G" L=64 steps=4000 snap_every=1000 \
         ckpt_every=2000 log_every=1000 > "$LOGDIR/proefrun_gpu.log" 2>&1 && [ -f "$G/snap_0000004000.bin" ]; then
      ms=$(grep -o '[0-9.]* ms/step' "$G/log.txt" | tail -n1)
      res OK "GPU-proefrun" "oercel_gpu L=64, 4000 stappen ($ms)"
    else
      res FOUT "GPU-proefrun" "oercel_gpu proefrun mislukt: $(tail -n3 "$LOGDIR/proefrun_gpu.log" | tr '\n' ' ')"
    fi
    rm -rf "$G"
  fi
  rm -rf "$S"
  if as_owner python3 "$PC_DIR/status.py" --kort > /dev/null 2>&1; then res OK "pc-scripts" "pc/status.py werkt"
  else res FOUT "pc-scripts" "pc/status.py faalt"; fi
fi
# tools/selftest.py: analysis + all image kinds + video on SYNTHETIC data (never a simulation result), kill -9
# robustness; ~1-2 minutes, 2 processes.  Exit code = number of failed checks.
if [ "$DO_VALIDATE" = 1 ] && [ -n "$TOOLS_PY" ] && [ -f "$CEL/tools/selftest.py" ]; then
  info "tools/selftest.py (analyse en beelden op synthetische testdata, 1-2 minuten) ..."
  TS=$LOGDIR/tools_selftest
  rm -rf "$TS"; mkdir_owner "$TS"
  as_owner timeout 1800 "$TOOLS_PY" "$CEL/tools/selftest.py" --dir "$TS" > "$LOGDIR/tools_selftest.log" 2>&1
  trc=$?
  tp=$(grep -c '^PASS' "$LOGDIR/tools_selftest.log"); tf=$(grep -c '^FAIL' "$LOGDIR/tools_selftest.log")
  grep -E '^(PASS|FAIL)' "$LOGDIR/tools_selftest.log" | sed 's/^/    /' | cut -c1-160
  # without ffmpeg only the video check can fail; that is a warning, like the missing ffmpeg itself (step 3)
  tfv=$tf; [ "$FFOK" = 0 ] && tfv=$(grep '^FAIL' "$LOGDIR/tools_selftest.log" | grep -vc 'video\.py')
  if [ "$trc" = 0 ] && [ "$tf" = 0 ] && [ "$tp" -gt 0 ]; then
    res OK "tools-zelftest" "tools/selftest.py: PASS ($tp controles, synthetische data)"
  elif [ "$FFOK" = 0 ] && [ "$tfv" = 0 ] && [ "$trc" = "$tf" ] && [ "$tp" -gt 0 ]; then
    res WAARSCHUWING "tools-zelftest" "tools/selftest.py: PASS ($tp controles), alleen video.py faalt: ffmpeg ontbreekt"
  else
    res FOUT "tools-zelftest" "tools/selftest.py: FAIL ($tf van $((tp + tf)) controles, code $trc; log: $LOGDIR/tools_selftest.log): $(grep -m2 '^FAIL' "$LOGDIR/tools_selftest.log" | cut -c7-90 | tr '\n' ' ')"
  fi
  rm -rf "$TS"
elif [ "$DO_VALIDATE" != 1 ]; then
  res OVERGESLAGEN "tools-zelftest" "tools/selftest.py niet gedraaid (--snel/--geen-tests)"
else
  res OVERGESLAGEN "tools-zelftest" "tools/selftest.py niet gedraaid (geen werkende Python, zie boven)"
fi
if [ "$DO_VALIDATE" = 1 ] && [ -x "$CEL/engine/oercel" ] && [ -n "$TOOLS_PY" ]; then
  info "engine/tests/validate.sh (1-3 minuten) ..."
  as_owner bash "$CEL/engine/tests/validate.sh" "$LOGDIR/validate" > "$LOGDIR/validate.log" 2>&1
  np=$(grep -c '^PASS' "$LOGDIR/validate.log"); nf=$(grep -c '^FAIL' "$LOGDIR/validate.log")
  grep -E '^(PASS|FAIL)' "$LOGDIR/validate.log" | sed 's/^/    /' | cut -c1-160
  [ "$nf" = 0 ] && [ "$np" -gt 0 ] && res OK "validatie" "engine/tests/validate.sh: $np PASS" \
    || res FOUT "validatie" "engine/tests/validate.sh: $np PASS, $nf FAIL (log: $LOGDIR/validate.log)"
  rm -rf "$LOGDIR/validate"
else
  res OVERGESLAGEN "validatie" "engine/tests/validate.sh niet gedraaid"
fi
if [ "$DO_TESTS" = 1 ] && [ "$GPU_ENGINE" = 1 ]; then
  if [ -x "$CEL/engine_gpu/selftest_gpu.sh" ] || [ -f "$CEL/engine_gpu/selftest_gpu.sh" ]; then
    if [ "$DO_VALIDATE" = 1 ]; then STQ=""; info "engine_gpu/selftest_gpu.sh (volledig, 10-20 minuten) ..."
    else STQ="--quick"; info "engine_gpu/selftest_gpu.sh --quick ..."; fi
    if as_owner bash "$CEL/engine_gpu/selftest_gpu.sh" $STQ > "$LOGDIR/selftest_gpu.log" 2>&1; then ST_OK=true; else ST_OK=false; fi
    # remember the verdict for exactly this binary: longrun.py --engine auto then avoids a GPU build that failed
    ST_SHA=$(sha1sum "$CEL/engine_gpu/oercel_gpu" 2>/dev/null | cut -c1-16)
    printf '{"ok": %s, "sha1": "%s", "time": "%s", "quick": %s, "log": "%s"}\n' "$ST_OK" "$ST_SHA" "$(date '+%Y-%m-%d %H:%M:%S')" \
      "$([ -n "$STQ" ] && echo true || echo false)" "runs/_setup/selftest_gpu.log" > "$PC_DIR/_build/gpu_selftest.json"
    if [ "$ST_OK" = true ]; then
      res OK "GPU-zelftest" "engine_gpu/selftest_gpu.sh geslaagd ($(grep -c PASS "$LOGDIR/selftest_gpu.log") PASS)"
    else
      res FOUT "GPU-zelftest" "engine_gpu/selftest_gpu.sh faalt (log: $LOGDIR/selftest_gpu.log): $(grep -m3 FAIL "$LOGDIR/selftest_gpu.log" | tr '\n' ' ') — longrun.py gebruikt dan de CPU-engine"
    fi
  else
    res OVERGESLAGEN "GPU-zelftest" "engine_gpu/selftest_gpu.sh bestaat niet"
  fi
fi
[ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ] && chown -R "$OWNER": "$LOGDIR" 2>/dev/null

# ------------------------------------------------------------------------------------- samenvatting
hdr "SAMENVATTING"
nfout=0
for i in "${!R_NAME[@]}"; do
  printf '  %-13s %-16s %s\n' "${R_STAT[$i]}" "${R_NAME[$i]}" "${R_MSG[$i]}"
  [ "${R_STAT[$i]}" = FOUT ] && nfout=$((nfout + 1))
done
echo
if [ "$nfout" = 0 ]; then
  echo "Klaar. Volgende stap: start Claude Code in de repo (claude remote-control) — Claude kan nu draaien met:"
  echo "  python3 cel/pc/status.py                       overzicht"
  echo "  python3 cel/pc/sweep.py <jobbestand> --achtergrond   parameter-sweep over alle kernen"
  echo "  python3 cel/pc/longrun.py <naam> --ini ... --achtergrond  lange run op de GPU"
else
  echo "$nfout onderdeel/onderdelen met FOUT (zie boven en $LOG)."
  [ "$NO_ROOT" = 1 ] && echo "Root ontbrak: draai dit script één keer zelf in een terminal (vraagt je wachtwoord): bash $PC_DIR/setup_wsl.sh"
fi
[ "$GPU_OK" = 1 ] || [ "$DO_CUDA" = 0 ] || echo "Zonder werkende GPU valt longrun.py automatisch terug op de CPU-engine."
echo "Log: $LOG"
exit $(( nfout > 0 ))
