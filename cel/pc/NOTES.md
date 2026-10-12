# pc/ — NOTES (crash-safe progress log)

Task: WSL2 workstation tooling (setup_wsl.sh, sweep.py, longrun.py, status.py, README.md).
Test outputs go to pc/_test/ (git-ignored via pc/.gitignore), never to runs/ of other teams.

## Findings so far
- developer.download.nvidia.com is BLOCKED by the egress proxy here (403) -> CUDA repo cannot be
  checked live. Ubuntu's official WSL doc (ubuntu.com/wsl/docs/latest/howto/gpu-cuda) confirms:
  wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i ...; apt-get update; apt-get install cuda-toolkit-13-2 (current example). Never install
  `cuda`, `cuda-13`, `cuda-drivers` (pull Linux driver).
- engine: walltime=S -> clean stop + ckpt; SIGTERM same; restart=outdir/ckpt.bin into same dir is
  bitwise identical; ckpt_keep=1 hard-links ckpt_<step>.bin; tmp files *.tmp left on kill -9.
- `oercel --params` prints a markdown table of keys -> used for engine capability detection.
- runs/memB_src is under runs/ = git-ignored -> NOT on GitHub. Support any engine via --engine PATH.
- CLAUDE.md (repo root) already references pc/ scripts. User rejects HTML/artifacts.
- sudo password problem: Claude Code (non-interactive) cannot type sudo password -> setup must be
  run once by the user in a terminal (or `wsl -u root`), non-root parts still work.

## Design
- pc/pclib.py shared helpers (stdlib only): paths, engine detection, chunk runner, locks, state.
- runs/<run>/pc_longrun.json + STATUS.md ; runs/<sweep>/pc_sweep.json + SAMENVATTING.md

## Status
- [x] read SPEC/engine/tools
- [x] pclib.py
- [x] longrun.py + tests
  - tests/test_longrun_kill.sh PASS (02:25): kill -9 engine, kill -9 supervisor (engine stops via
    PDEATHSIG with ckpt), kill -9 both; final stats/events/ckpt + 61 snapshots bitwise == reference.
  - tests/test_thinning.sh PASS (02:27): adopted copy of runs/memA_F0 (division at 92000): window kept,
    51 -> 20 snaps, re-analysis still finds division, micro/goodsell/timelapse rendered.
- [x] sweep.py + tests
  - tests/test_sweep_kill.sh PASS (02:31): 8 jobs, kill -9 engine + kill -9 sweep supervisor, resume;
    2 jobs bitwise == uninterrupted reference; SAMENVATTING.md/.csv OK.
- [ ] status.py
- [ ] setup_wsl.sh + dry-run tests
- [ ] README.md
