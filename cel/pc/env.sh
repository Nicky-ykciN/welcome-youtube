# shellcheck shell=bash
# Oercel: omgeving voor een shell op de werkplek.   Gebruik:  source cel/pc/env.sh
# - zet de Python-venv van setup_wsl.sh (cel/pc/.venv) vooraan in PATH, als die bestaat
# - zet de CUDA-toolkit (/usr/local/cuda/bin) in PATH, als die bestaat
# setup_wsl.sh voegt deze regel alleen aan ~/.bashrc toe als de venv nodig was.
_oercel_pc=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
if [ -x "$_oercel_pc/.venv/bin/python" ]; then
  case ":$PATH:" in *":$_oercel_pc/.venv/bin:"*) ;; *) export PATH="$_oercel_pc/.venv/bin:$PATH" ;; esac
fi
if [ -d /usr/local/cuda/bin ]; then
  case ":$PATH:" in *":/usr/local/cuda/bin:"*) ;; *) export PATH="/usr/local/cuda/bin:$PATH" ;; esac
fi
[ -f /etc/profile.d/oercel-cuda.sh ] && . /etc/profile.d/oercel-cuda.sh
export OERCEL_CEL="$(dirname "$_oercel_pc")"
unset _oercel_pc
