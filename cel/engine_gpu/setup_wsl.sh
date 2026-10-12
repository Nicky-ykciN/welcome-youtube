#!/bin/bash
# Prepare a WSL2 (Ubuntu) machine with an NVIDIA GPU for oercel_gpu.  Idempotent: run it as
# often as you like; it only installs what is missing.
#
#   engine_gpu/setup_wsl.sh            check + install prerequisites, then build oercel_gpu
#   engine_gpu/setup_wsl.sh --check    only report what is there / missing (installs nothing)
#
# What it needs and how it gets it:
#   - the GPU itself: in WSL2 the *Windows* NVIDIA driver provides it (/usr/lib/wsl/lib/libcuda.so,
#     nvidia-smi).  Never install a Linux NVIDIA driver inside WSL2.  If nvidia-smi fails, update the
#     Windows driver (any driver >= 525 works for the CUDA 12 runtime used here).
#   - g++, make: apt package build-essential (needs sudo once).
#   - python3 with numpy, scipy, matplotlib, pandas, PIL (tools/ and the self-test): apt packages
#     (needs sudo once).
#   - nvcc (CUDA compiler): if no nvcc is found, the CUDA 12.6 compiler, runtime and headers are
#     downloaded from NVIDIA's redistributable archives into engine_gpu/.cuda (no sudo, ~0.2 GB,
#     nothing system-wide).  Set CUDA_REDIST_VERSION to choose another 12.x release.
#     (Ubuntu's own apt package nvidia-cuda-toolkit is avoided on purpose: in WSL2 it pulls in Linux
#     driver libraries whose libcuda.so can shadow the WSL one.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
ok()   { echo "  [ok]      $*"; }
miss() { echo "  [missing] $*"; }
note() { echo "  [note]    $*"; }
# sudo: root needs none; passwordless sudo is used silently; otherwise sudo asks once on a terminal
SUDO=""
CAN_SUDO=1
if [ "$(id -u)" != 0 ]; then
  SUDO="sudo"
  if ! sudo -n true 2>/dev/null; then
    if [ -t 0 ]; then echo "(sudo will ask for your Linux password for apt-get)"; else CAN_SUDO=0; fi
  fi
fi

echo "== 1. GPU / driver (provided by Windows in WSL2) =="
if grep -qi microsoft /proc/version 2>/dev/null; then ok "running under WSL ($(uname -r))"; else note "not WSL2 ($(uname -r)) - fine on native Linux too"; fi
NVSMI=$(command -v nvidia-smi || ls /usr/lib/wsl/lib/nvidia-smi 2>/dev/null || true)
if [ -n "$NVSMI" ] && "$NVSMI" -L >/dev/null 2>&1; then
  ok "$("$NVSMI" -L | head -n 3 | tr '\n' ' ')"
  "$NVSMI" --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader 2>/dev/null | sed 's/^/            /'
else
  miss "nvidia-smi does not see a GPU. In WSL2: install/update the NVIDIA driver on WINDOWS, then 'wsl --shutdown' and reopen."
fi
if ls /usr/lib/wsl/lib/libcuda.so* >/dev/null 2>&1; then ok "WSL libcuda: $(ls /usr/lib/wsl/lib/libcuda.so.1 2>/dev/null)"; fi
SHADOW=$(ldconfig -p 2>/dev/null | grep 'libcuda.so.1 ' | grep -v /usr/lib/wsl | head -n 1)
if [ -n "$SHADOW" ] && [ -e /usr/lib/wsl/lib/libcuda.so.1 ]; then
  note "a non-WSL libcuda is installed ($SHADOW); if oercel_gpu reports 'no CUDA device', remove the Linux driver packages (e.g. libnvidia-compute-*)"
fi

echo "== 2. compiler and tools (apt) =="
APT_PKGS=""
command -v g++ >/dev/null && ok "g++ $(g++ -dumpversion)" || { miss g++; APT_PKGS="$APT_PKGS build-essential"; }
command -v make >/dev/null && ok "make" || { miss make; APT_PKGS="$APT_PKGS make"; }
command -v python3 >/dev/null && ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)" || { miss python3; APT_PKGS="$APT_PKGS python3"; }
for m in numpy:python3-numpy scipy:python3-scipy matplotlib:python3-matplotlib pandas:python3-pandas PIL:python3-pil; do
  mod=${m%%:*}; pkg=${m##*:}
  if python3 -c "import $mod" >/dev/null 2>&1; then ok "python3 module $mod"; else miss "python3 module $mod"; APT_PKGS="$APT_PKGS $pkg"; fi
done
command -v ffmpeg >/dev/null && ok "ffmpeg (videos)" || { miss "ffmpeg (only for tools/video.py)"; APT_PKGS="$APT_PKGS ffmpeg"; }
command -v curl >/dev/null || APT_PKGS="$APT_PKGS curl"
command -v xz >/dev/null || APT_PKGS="$APT_PKGS xz-utils"
if [ -n "$APT_PKGS" ]; then
  if [ $CHECK_ONLY = 1 ]; then note "would run: $SUDO apt-get install -y$APT_PKGS"
  elif [ $CAN_SUDO = 0 ]; then
    echo "  cannot install$APT_PKGS: sudo needs a password and there is no terminal."
    echo "  Run once in a WSL terminal:  sudo apt-get install -y$APT_PKGS   and start this script again."
    exit 1
  else
    echo "  installing:$APT_PKGS  (sudo may ask for your Linux password once)"
    $SUDO apt-get update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_PKGS || { echo "apt-get failed"; exit 1; }
  fi
fi

echo "== 3. CUDA compiler (nvcc) =="
find_nvcc() {
  for c in "${NVCC:-}" "$HERE/.cuda/bin/nvcc" "$(command -v nvcc 2>/dev/null)" /usr/local/cuda/bin/nvcc /usr/local/cuda-12*/bin/nvcc; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
NVCC_BIN=$(find_nvcc || true)
if [ -n "$NVCC_BIN" ]; then
  ok "nvcc: $NVCC_BIN ($("$NVCC_BIN" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p'))"
elif [ $CHECK_ONLY = 1 ]; then
  miss "nvcc (would download the CUDA ${CUDA_REDIST_VERSION:-12.6.3} redistributables into $HERE/.cuda)"
else
  V=${CUDA_REDIST_VERSION:-12.6.3}
  BASE=https://developer.download.nvidia.com/compute/cuda/redist
  echo "  downloading CUDA $V compiler + runtime + headers from $BASE (no sudo, into $HERE/.cuda)"
  TMP=$(mktemp -d)
  curl -fsSL "$BASE/redistrib_$V.json" -o "$TMP/r.json" || { echo "cannot download $BASE/redistrib_$V.json"; exit 1; }
  mkdir -p "$HERE/.cuda"
  for comp in cuda_nvcc cuda_cudart cuda_cccl cuda_crt libnvvm; do   # crt/libnvvm are separate only in newer releases
    rel=$(python3 -c "import json,sys; d=json.load(open('$TMP/r.json')); print(d.get('$comp',{}).get('linux-x86_64',{}).get('relative_path',''))")
    [ -z "$rel" ] && continue
    echo "    $comp: $rel"
    curl -fsSL "$BASE/$rel" -o "$TMP/a.tar.xz" || { echo "download of $rel failed"; exit 1; }
    tar -xJf "$TMP/a.tar.xz" -C "$TMP" || exit 1
    d=$(tar -tJf "$TMP/a.tar.xz" | head -n 1 | cut -d/ -f1)
    cp -a "$TMP/$d/." "$HERE/.cuda/"
    rm -rf "$TMP/$d" "$TMP/a.tar.xz"
  done
  rm -rf "$TMP"
  [ -d "$HERE/.cuda/lib" ] && [ ! -e "$HERE/.cuda/lib64" ] && ln -s lib "$HERE/.cuda/lib64"
  # nvcc.profile may look in targets/x86_64-linux/{include,lib}: provide both layouts
  mkdir -p "$HERE/.cuda/targets/x86_64-linux"
  [ -e "$HERE/.cuda/targets/x86_64-linux/include" ] || ln -s ../../include "$HERE/.cuda/targets/x86_64-linux/include"
  [ -e "$HERE/.cuda/targets/x86_64-linux/lib" ] || ln -s ../../lib "$HERE/.cuda/targets/x86_64-linux/lib"
  [ -e "$HERE/.cuda/targets/x86_64-linux/lib64" ] || ln -s ../../lib "$HERE/.cuda/targets/x86_64-linux/lib64"
  NVCC_BIN=$(find_nvcc || true)
  [ -n "$NVCC_BIN" ] && ok "nvcc installed: $NVCC_BIN" || { echo "nvcc installation failed"; exit 1; }
fi
# fallback if the downloaded compiler cannot build: NVIDIA's official WSL-Ubuntu apt repository
try_official_cuda() {
  [ $CAN_SUDO = 1 ] || return 1
  . /etc/os-release
  echo "  installing cuda-toolkit-12-6 from NVIDIA's WSL-Ubuntu apt repository (sudo)"
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb &&
    $SUDO dpkg -i /tmp/cuda-keyring.deb && $SUDO apt-get update -qq &&
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-toolkit-12-6 && NVCC_BIN=/usr/local/cuda-12.6/bin/nvcc
}

if [ $CHECK_ONLY = 1 ]; then exit 0; fi
echo "== 4. build =="
CAP=$("${NVSMI:-nvidia-smi}" --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d ' .')
ARCH=${ARCH:-sm_${CAP:-75}}
if make -C "$HERE" NVCC="$NVCC_BIN" ARCH="$ARCH" oercel_gpu; then ok "built $HERE/oercel_gpu for $ARCH"
else
  note "build with $NVCC_BIN failed"
  if try_official_cuda && make -C "$HERE" NVCC="$NVCC_BIN" ARCH="$ARCH" oercel_gpu; then ok "built $HERE/oercel_gpu for $ARCH with $NVCC_BIN"
  else echo "build failed"; exit 1; fi
fi
make -C "$HERE" emu >/dev/null 2>&1 && ok "built $HERE/oercel_emu (CPU emulation)" || note "emulation build failed (not needed on the GPU machine)"
"$HERE/oercel_gpu" --version
echo "next: $HERE/selftest_gpu.sh"
