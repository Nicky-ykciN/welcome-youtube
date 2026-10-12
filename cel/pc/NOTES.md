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
- [x] status.py (tested on all test run dirs)
- [~] setup_wsl.sh: --test-functies 15/15 PASS; mock-repo dry run (scratchpad/mockrepo, fake
  /proc/version + fake nvidia-smi): validate 29 PASS, proefrun OK, CUDA test compiled with nvcc 12.0 for
  sm_75 (run fails: no GPU here, expected). apt pin verified with apt-cache policy (drivers -> none).
  NOTE: this machine has libnvidia-compute-535/580 (teammate apt nvidia-cuda-toolkit) -> setup flags it.
- [ ] README.md

## More tests
- tests/test_longrun_extra.sh PASS (02:44): auto->GPU path with fake nvidia-smi + stand-in GPU binary
  (OERCEL_ENGINE_GPU), --stop, status.py resume line, corrupt ckpt -> fallback to older copy -> bitwise
  identical, unknown key refused, --van-ckpt == direct engine restart.
- voorbeelden/*.txt|json: --proef OK; memB example refused by CPU engine with clear msg; tiny real sweep
  with --engine runs/memB_src/oercel OK (found+fixed: memB ckpt v3 header has step at offset 24).
- tests/test_longrun_extra.sh now also: --van-ckpt + restart_reseed=1 reseeds only the first chunk
  (fixed: was passed every chunk) -> equals one direct branched engine run. PASS 02:5x.
- tests/test_reboot.sh PASS: power cut of longrun+sweep, `status.py --hervat` resumes both.
  (first version of this test killed its own shell by a too-broad cmdline match -> fixed, only own pids)
- disk guard (min_free_gb, OERCEL_TEST_DISK_FREE_FILE hook): tests/test_disk_guard.sh PASS.
- integration with engine_gpu (teammate): find_nvcc also engine_gpu/.cuda; no-root fallback runs
  engine_gpu/setup_wsl.sh (redist nvcc); build with make NVCC=.. [CCBIN=..] oercel_gpu; selftest full
  (--snel -> --quick). Removed global NVCC_PREPEND_FLAGS (would duplicate -ccbin with their Makefile).
  Mock setup built oercel_gpu with nvcc 12.0 + g++-12 OK.
- test_longrun_kill.sh with ENGINE=engine_gpu/oercel_emu (copy in _test/emu): PASS bitwise (02:58).
- progress is now measured by the durable (checkpoint) step; rc=0 without progress counts as failure.
- [x] README.md (Dutch)
- [x] final full re-run 02:59-03:08 (pc/_test/run_all.log): ALL PASS (kill, extra, thinning, sweep_kill,
  reboot, disk_guard, kill with oercel_emu, setup --test-functies).
- after that: longrun terminates analysis/render subprocess on --stop (tool_proc); setup: venv fallback
  when tools fail with system Python, proefrun now runs before validate.sh. Re-ran extra+thinning: PASS.
  Mock setup (--snel): proefrun OK, oercel_gpu built, GPU proefrun/selftest FAIL as expected (no GPU).
- tests/alle_tests.sh = one runner for everything (ENGINE_EMU=... adds the kill test with another engine).
- [x] tests/alle_tests.sh with ENGINE_EMU=engine_gpu/oercel_emu copy: ALL PASS 03:20-03:28
  (pc/_test/alle_tests.log; test run dirs deleted afterwards to save disk).
- [x] report delivered. DONE. A successor only needs: read README.md + this file.

## Incident (honest record)
- 02:42: while testing setup_wsl.sh with a FAKE WSL2 kernel string but WITHOUT --droog (as root on this
  shared machine) the script really wrote /etc/apt/preferences.d/oercel-geen-linux-nvidia-driver
  (an apt pin with priority -1 for nvidia driver packages). The NVIDIA downloads failed (host blocked),
  so nothing else happened (no keyring, no apt-get update, no profile.d, no nvcc wrapper). The pin file
  was removed within a minute (checked). Rule: on this machine test setup_wsl.sh ONLY with --droog or
  OERCEL_TEST_NO_ROOT=1.

## Requests for other teams / main session (not done by me: outside pc/)
1. runs/memB_src is under git-ignored runs/ -> its lip_arch features and binary are NOT on GitHub.
   Merge into engine/ (planned) or move the source out of runs/. sweep/longrun already accept any
   engine via --engine PATH and check keys against `<engine> --params` (memB ckpt v3 supported).
2. tools/analyze.py writes cells.json, lineage.json, checklist.json/.md with plain open('w'):
   a kill mid-write leaves truncated JSON. Suggest tmp + os.replace like its cache files.
3. engine/oercel.c write_snapshot() renames without fsync; after a power cut a recent snapshot can be
   empty/garbage (ext4 delayed allocation). Suggest fflush+fsync before rename (ckpt already does).
4. CLAUDE.md: mention `python3 cel/pc/status.py --hervat` after a reboot, always `--achtergrond`
   (10-min Bash limit), and that cel/pc/setup_wsl.sh is THE setup (engine_gpu/setup_wsl.sh is only
   its no-root nvcc fallback).
5. beelden/<run>/ is not git-ignored: longrun keeps only the newest 4 images per kind per run.

## REVIEW (independent reviewer, 2026-10-12, ~03:30-04:30 UTC) — progress log (stappen in volgorde)
- [ ] read all pc/ files (setup_wsl.sh, pclib, longrun, sweep, status, tests)  <- in progress
- findings + fixes are logged below as they happen
- [stap 1] read everything. Candidate findings (to reproduce/fix, in this order):
  A. longrun: GPU binary present but failing (no device / failed selftest) -> auto still picks GPU, no CPU fallback
  B. longrun/sweep: engine that fails at start for a NON-checkpoint reason (GPU gone) marks every checkpoint
     'bad' -> permanent 'fout' that needs manual JSON editing (new start does not reset bad_ckpts)
  C. setup_wsl.sh via `wsl -u root`: runs/, runs/_setup, pc/_build created root-owned -> owner-run builds,
     proefrun, validate fail; later user sweeps cannot create runs/<x>
  D. setup: apt lock (unattended-upgrades on fresh WSL) / interrupted dpkg / partial cuda-toolkit install
  E. status.py --hervat also restarts runs the user stopped on purpose (but SIGTERM at WSL shutdown must still resume)
  F. sweep: disk-low does not stop running engines; G. longrun busy -> --steps silently ignored
  H. --van-ckpt source may be a live run's ckpt.bin (changes under us); I. flock errors (drvfs) crash
  J. sweep with --engine gpu defaults to 63 parallel GPU jobs; K. thread oversubscription warning
- [stap 2] REPRODUCED A (fake nvidia-smi + real oercel_gpu that fails here: auto picked GPU, 6 crashes, 'fout')
  and B (transient GPU failure marked valid checkpoints bad). FIXES applied (pclib/longrun/sweep/status):
  gpu_engine_check (selftest marker pc/_build/gpu_selftest.json + cached 20-step smoke run), ckpt marking only
  on checkpoint errors/SEGV, reset of bad_ckpts on new start, stop marker pc_stop_verzoek (+stopped_by),
  disk-low -> analysis+thinning (longrun) / pause running engines (sweep), --van-ckpt frozen copy
  pc_van_ckpt.bin, busy run: 'NIET TOEGEPAST' rc=1, flock fallback (/tmp/oercel-locks-UID), warnings
  (/mnt, oversubscription), sweep --engine gpu default 4 jobs, status.py Dutch labels + thread usage.
  NEXT: re-run repro A/B, then setup_wsl.sh fixes (C, D), then tests + new kill-stress test.
- [stap 3] C REPRODUCED with the original setup (root on a mock repo owned by `nobody`, pc/_test/mock_root,
  --droog --snel --geen-cuda --geen-apt): proefrun FOUT 'cannot create directory runs/_setup/proefrun',
  runs/ left root-owned. FIXED (mkdir_owner before anything is written, chown in EXIT trap): rc=0, proefrun OK,
  runs/ + _build owned by the repo owner, owner can create runs/<x>.
  Also in setup: apt -o DPkg::Lock::Timeout=600, dpkg --configure -a when dpkg --audit complains,
  half-installed CUDA (cuda-nvcc-X-Y without cudart-dev) is completed, Ubuntu 20.04 -> CUDA <= 12.x,
  up to 3 toolkit candidates newest-first, minimal fallback cuda-nvcc+cudart-dev+cccl, broken venv repaired
  or moved aside, stale cuda_check removed before build, pc/_build/gpu_selftest.json marker.
  --test-functies 18/18 PASS. Repro A/B re-run after fix: A -> cpu/klaar; B -> no bad ckpts, resumes from ckpt.bin.
- [stap 4] more fixes: longrun renders to *.tmp.png + rename (render.py writes straight to --out: a kill left
  half PNGs in beelden/ forever); image pruning counts files on disk (no orphans after a kill between
  render and state save). New tests written: tests/test_gpu_fallback.sh, tests/test_stop_hervat.sh,
  tests/test_kill_stress.sh (added to alle_tests.sh). test_longrun_extra uses a private smoke cache.
  Full old suite re-run in background -> pc/_test/review/alle_tests_na_fix.log (first 3 tests PASS).
- [stap 5] old suite (6 tests) ALL PASS with the fixes (pc/_test/review/alle_tests_na_fix.log; the final
  'syntax error' line is an artefact: I edited alle_tests.sh while bash was reading it).
  FIX: hint commands said `python3 pc/longrun.py ...` (relative to cel/) -> fail from the repo root where
  Claude works. Now P.shown_cmd(): files -> `python3 cel/pc/...` (repo root), terminal -> relative to cwd
  (absolute outside the repo); --runs-dir shown absolute; status.py --hervat executes absolute paths.
  NEXT: run tests/test_gpu_fallback.sh, test_stop_hervat.sh, test_kill_stress.sh.
- [stap 6] tests/test_gpu_fallback.sh: 14/14 PASS (pc/_test/review/gpu_fallback.txt).
  setup as non-root user without sudo (mock pc/_test/mock_user, run as nobody): non-root path works
  (build, proefrun OK; apt FOUT + "Root ontbrak" hint, correct). Small fixes: find_nvcc requires
  `nvcc --version` to work (dangling /usr/local/bin/nvcc wrapper), python3-* apt packages skipped when
  python3 already imports everything (python3-venv kept). longrun: sync_images() (tmp cleanup + adopt
  orphan images + prune) at each render and at supervisor end.
  NEXT: run test_stop_hervat.sh then test_kill_stress.sh.
- [stap 7] test_stop_hervat.sh run 1: sections 1-3 PASS (SIGTERM->signaal->--hervat resumes; --steps on running
  run -> NIET TOEGEPAST rc=1; --stop -> gebruiker). Section 4 FAILED because of MY test hook
  (OERCEL_TEST_NO_FLOCK also broke the /tmp fallback) -> hook fixed (only non-fallback paths fail). Re-run next.
  sweep --engine gpu: cap message only when it reduces parallelism (4 on 128 CPUs).
- [stap 8] test_stop_hervat run 1: 25 PASS, 3 FAIL all in section 4 = my hook bug (fixed). Sections 1,2,3,5 PASS
  (sweep disk-low pause: engines stop with ckpt, 0 crashes counted, bitwise identical after resume).
  NEW FIX (WSL2): statvfs inside WSL2 shows the virtual disk (up to 1 TB), not the Windows drive the
  ext4.vhdx grows on -> disk guard now uses min(Linux fs, /mnt/c) in WSL (P.disk_free_detail, reason in
  logs/STATUS); status.py shows "Windows C: vrij" (BIJNA VOL < 30 GB). Untestable here (no WSL); hook
  OERCEL_TEST_HOST_FREE_FILE. thin(): cache files deleted before the snapshot.
  NOW: running tests/test_kill_stress.sh -> pc/_test/review/kill_stress.txt
- [stap 9] dry setup in fake WSL2 (pc/_test/mock_dry, test hooks force --droog; no pin written to /etc - checked):
  20.04 -> "alleen CUDA 12.x" (fixed dry placeholder 13-0 -> 12-x), 24.04 + --cuda-versie 12-6 OK, apt
  commands carry DPkg::Lock::Timeout=600. Stress test first attempt had a test bug (ref dirs not created,
  engine mkdir is one level) -> fixed; early output showed targeted kills landing inside ckpt.bin.tmp
  writes (8/8 'still there: True'). Re-running.
- [stap 10] test_kill_stress part A PASS: 11 kill -9 landed while ckpt.bin.tmp was being written (engine,
  supervisor->SIGTERM mid-write, both), + snapshot-write kill + random kills: 481 snapshots, stats.csv,
  events.csv, ckpt.bin bitwise identical; no *.tmp left; 3 ckpt copies; no checkpoint marked bad.
  Also: remaining hint paths (STATUS.md signal text, 'draait al' lines) now repo-correct (P.shown_path).
- Requests for other teams found by this review (cannot change outside pc/):
  R1 engine/oercel.c: also fsync stats.csv/events.csv (fflush only) and snapshots before write_ckpt, and
     fsync the directory after the renames. In WSL2 `wsl --shutdown` / a Windows-update reboot drops the
     VM page cache like a power cut: rows/snapshots BEFORE the fsynced checkpoint can be lost and are never
     rewritten (engine resumes after them). pc cannot repair this (it would need an older ckpt copy).
  R2 tools/render.py: write --out via tmp + os.replace (longrun now works around it with *.tmp.png).
  R3 tools/analyze.py: atomic JSON outputs (same as the author's request 2).
  R4 CLAUDE.md: commands from the repo root are `python3 cel/pc/...`; `--stop` = deliberate (not auto-
     resumed by status.py --hervat); a change on a running run says NIET TOEGEPAST (rc 1): --stop first.
- [stap 11] test_kill_stress part B: 7 supervisor kills, all landed during analyze.py (render.py not hit
  because the soup has no cells -> only micro render, short). TODO after this run: target render.py too.
  setup: dpkg repair now respects --geen-apt.
- [stap 12] tests/test_kill_stress.sh ALL PASS (pc/_test/review/kill_stress.txt): A as above; B 7 supervisor
  kills during analyze.py -> klaar, valid JSON, 0 stale cache, no *.tmp.png, image set == state, 50 remaining
  snapshots + ckpt + stats bitwise identical; C 6 sweep-supervisor kills (also during analyses) -> 6/6
  analysed, 2 jobs bitwise identical. Then: part B now also targets render.py (4 of 9 kills); job-state
  labels shared (P.JOB_LABEL) for status.py and sweep STATUS.md/SAMENVATTING.md.
  NEXT: full suite pc/tests/alle_tests.sh (9 tests + emu kill test + --test-functies) -> pc/_test/review/final.log
- [stap 13] final suite in progress (pc/_test/review/final.log): kill, extra, thinning, sweep_kill, reboot,
  disk_guard, gpu_fallback (14/14), stop_hervat (21/21, incl. the flock fallback) ALL PASS so far.
  Disk tests now also set OERCEL_TEST_HOST_FREE_FILE (deterministic on WSL2 where C: is checked).
- [stap 14] FINAL: full suite pc/tests/alle_tests.sh with ENGINE_EMU (copy of engine_gpu/oercel_emu): ALL PASS
  rc=0 (pc/_test/review/final.log): longrun_kill, longrun_extra, thinning, sweep_kill, reboot, disk_guard,
  gpu_fallback 14/14, stop_hervat 21/21, kill_stress 19/19 (11 kills inside ckpt writes, 9 supervisor kills
  incl. 4 during render.py, 6 sweep-supervisor kills), emu kill test, setup --test-functies 18/18.
  Final setup end-to-end as root on a nobody-owned mock with fake WSL2 + fake nvidia-smi (forced --droog):
  proefrun OK, runs/ runs/_setup pc/_build owned by the repo owner, no files written to /etc (checked).
  Test run dirs + mocks deleted; logs kept in pc/_test/ and pc/_test/review/. REVIEW DONE.
  Still untestable here: real WSL2/CUDA/GPU, sudo prompt, /mnt/c (drvfs flock, C: free space), 64-core sizing.
  Note: pc/README.md, pc/tests/* (most) and pc/voorbeelden/ are not yet tracked by git -> whoever commits
  must add the whole cel/pc directory (git status showed them as untracked; read-only check).

## START-TAAK (one-command start: start.sh, stop.sh, plan.txt, plan.py, STARTEN.md) — 2026-10-12 vanaf 04:35
Opdracht: pc/start.sh (setup indien nodig -> claude installeren -> plan starten/hervatten -> status
--kort -> Claude Remote Control in tmux 'oercel-claude'), pc/stop.sh, pc/plan.txt, voorbeelden/leven_scan.txt,
/home/user/welcome-youtube/STARTEN.md, README-verwijzing. Geen git. engine/, engine_gpu/, SPEC, CLAUDE.md, runs/
(behalve eigen testmappen) NIET aanraken. Tests licht (1-2 threads, kleine dozen). setup_wsl.sh hier NOOIT
echt draaien (root! zie Incident): in tests een nep-setup via OERCEL_SETUP_CMD.
Ontwerp (besloten):
- setup klaar = nieuwste niet-DROOG runs/_setup/setup_*.log bevat "Klaar. Volgende stap" (+ engine/oercel bestaat).
  Eerdere poging mislukt en CPU-engine+python werken -> eerst plan hervatten, dan setup opnieuw, dan plan nogmaals.
- plan.py (stdlib + pclib): regels 'longrun.py ...' / 'sweep.py ...', '#'-commentaar, '\'-vervolgregels,
  'als PAD bestaat: ...' / 'anders: ...' (production.ini-terugval). Per regel: nieuw -> start; draait -> niets;
  klaar -> niets; bewust gestopt (--stop) zonder stop.sh-merkteken -> blijft staan; anders hervatten.
  Daarna: andere onderbroken runs/sweeps (status.py-logica) + alles met stop.sh-merkteken hervatten.
- oersoep_groot met --engine gpu (geen CPU-terugval: L=512 op 32 CPU-threads zou de sweep overboeken).
- sweep leven_scan: 54 varianten x 2 seeds = 108 jobs, --threads 2 --reserve 20 -> 54 tegelijk op 128 threads.
- stop.sh: merkteken pc_gestopt_door_stop_sh in elke draaiende run/sweep + --stop (parallel); --alles ook tmux.
- Claude RC: wrapper pc/claude_rc.sh in tmux (herstart na netwerkverlies, --continue bij herstart).
Voortgang:
- [04:50] geschreven: plan.py (start/lijst/proef/stop), plan.txt, voorbeelden/leven_scan.txt (108 jobs),
  claude_rc.sh (tmux-wrapper), start.sh, stop.sh, pc/.gitattributes (LF), setup_wsl.sh PKGS + curl tmux.
  plan.py proef op het echte plan: 0 fouten (CPU-engine accepteert de terugvalregel; sweep --proef 108 jobs).
  Snelheid hier: L=100 chemie aan, 2 threads: 1,3 ms/stap. VOLGENDE: tests (pc/tests/test_start.sh) met nep-HOME,
  nep-claude/curl/nvidia-smi, echte tmux op eigen socket (-L), nep-setup (OERCEL_SETUP_CMD), OERCEL_RUNS in scratch.
- [04:58] tests/test_start.sh geschreven (14 secties); eerste run gestart -> _test/start.log
- [05:00] eerste testrun: 13 secties PASS; 1 FAIL = testfout (wait_for evalueerde $(..) maar één keer) -> wait_for
  eval't nu een string. Wrapper herstart Claude wel echt (claude_rc.log). Daarna gewijzigd: plan.py draait scripts
  vanuit de repo-root (hints 'python3 cel/pc/...'); setup wordt na 3 mislukte pogingen op rij niet meer
  automatisch herhaald (behalve als nvidia-smi nu werkt en het log 'nvidia-smi werkt niet' had, of als CPU-engine/
  python ontbreken); --setup forceert. STARTEN.md (root) en README.md (§0 start.sh, tabel, tests, niet-getest) klaar.
  VOLGENDE: test sectie 8 uitbreiden (3x mislukt -> niet meer; --setup; gpu-uitzondering), test opnieuw draaien.
- [05:10] testrun 2: 74 PASS, 0 FAIL (incl. sectie 8 met herhaal-limiet). Leftover-processen: zie volgende regel
- [05:15] start.sh --help/stop.sh --help netjes (alleen kopcommentaar). leven_scan: 108 jobs, 0 onbekende sleutels
  (CPU- en GPU-engine), 3 jobs (eerste/midden/laatste) met alle waarden 200 stappen door engine/oercel: OK.
  Terugvalregel oersoep_groot door engine_gpu/oercel_emu (L=24, 50 stappen): OK. plan.py start --droog op het
  echte plan: juiste commando's (absolute paden). Testdata opgeruimd (transcripts blijven in _test/start/).
  Laatste volledige testrun loopt (_test/start.log). Daarna: eindrapport.
- [05:22] laatste volledige testrun: 74 PASS, 0 FAIL (_test/start.log). Geen achtergebleven processen. KLAAR -> rapport.

## REVIEW START-TAAK (independent reviewer #2, 2026-10-12) — simulate the user tomorrow following STARTEN.md
Scope: fix only in cel/pc/ and STARTEN.md. Tests: fake HOME/PATH stand-ins, tiny CPU runs, 1-2 threads,
test dirs under cel/pc/_test/review2/. setup_wsl.sh NEVER for real here (root; see Incident).
- [stap 0] read CLAUDE.md, STARTEN.md, start.sh, stop.sh, claude_rc.sh, plan.txt, plan.py, setup_wsl.sh, NOTES.
- [stap 1] simulations harness: pc/_test/review2/sim/ (env.sh = stand-ins incl. fake 'sudo password' prompt in the fake
  setup, fake claude with Trust [y/N] + Enable (y/n) + --continue; scenA.sh/scenB.sh ...).
  A (fresh user, literally STARTEN): PASS end to end.
  B (user presses Ctrl+b d before answering Trust, runs start.sh again): BUG CONFIRMED — start.sh says
  "draait al" and never shows the waiting prompt -> Claude never reaches the app. Root cause 1: the
  "peek for prompts" used `tmux capture-pane -t =SES`, which tmux 3.4 rejects ("can't find pane") -> the
  later-start prompt detection NEVER worked (the author's test only checked the negative case).
  Root cause 2: no prompt check at all in the 'draait'/'herstart' case. FIX NEXT in start.sh.
  Other findings so far (to fix): lock held while the user sits attached in tmux (blocks Claude's
  start.sh --alleen-plan); STARTEN 'claude auth login' fails in the same window (PATH); setup's "Volgende
  stap: start Claude Code" text inside start.sh misleads; lifeB_src engine has new keys (feed_duty,
  feed_period, stir_duty, stir_mode, stir_period) unknown to engine/ and engine_gpu/ -> if production.ini
  uses them, the 'als' line of oersoep_groot fails with FOUT every start (report, outside pc/).
- [stap 2] FIXED in start.sh: rc_asks() (capture-pane -t "=SES:", only lines after the last claude.ai/code link,
  last 8 lines) used after a new session AND when Claude 'draait al'; offer_attach() shared; lock released
  before attaching; after detach: warning if a question is still open; "Volgende stap" note after setup;
  PATH hint in summary; login fallback says "kies je Claude-abonnement". STARTEN.md rewritten (see report).
  Scenarios A, B (now PASS: second start brings the user back to the waiting question), C (two terminals:
  second says 'draait al', setup 1x; Claude's start.sh --alleen-plan works while user is attached),
  D (reboot: resume + --continue + re-asked Trust shown; no attach without a question; --continue failure
  -> wrapper retries without) ALL PASS. NEXT: fix test_start.sh section 12 (its negative check matched an
  old text), BLAS env for tool processes, plan/production.ini checks, disk/thread numbers.
- [stap 3] measured: analyze.py on a 121-snapshot L=100 run: 132 MB max RSS, 9 s (54 at once ~7 GB: ok).
  Fallback chemistry L=48 30k steps: snapshot 10.6 B/bead (L=512: 8.3 MB), ckpt 58 B/bead (L=512: 45 MB),
  events.csv 1.6e-8 B/bead/step (L=512, 50M steps: ~0.6 GB). oersoep_groot disk is bounded by
  --max-snap-gb 50 (+~1 GB) -> fine. Added pclib.tool_env() (OMP/OPENBLAS/MKL threads=1) for analysis/render
  subprocesses in longrun.py + sweep.py (pip numpy of the venv fallback would start a 128-thread pool per process).
  production.ini with unknown keys (scenP.sh): 'als' line FOUT every start, fallback not used, GPU idle ->
  message now says so + stale "runs/memB_src" hint in longrun replaced. lifeB_src engine HAS such keys.
- [stap 4] claude_rc.sh: after 5 quick failures it used to `exec bash -i` = Claude gone for good after a network
  outage > ~12 min (10 min server timeout + 5 x 30 s) until someone runs start.sh. Now: message stays, retry every
  10 min (OERCEL_RC_BACKOFF_S), marker _build/claude_rc.wacht; start.sh in that state restarts at once.
  scenN.sh (fake offline): ALL PASS. NEEDRESTART_MODE=a added to apt (setup_wsl.sh APT, start.sh apt_install).
  test_start.sh: section 12's negative check updated to the new text; new section 15 (question left open,
  lock free during attach). First full run: 1 FAIL = my own test quoting bug (pgrep matched its bash -c
  parent) -> fixed. README §0/tests/untested updated. NEXT: full test_start.sh again, then report.
- [stap 5] full tests/test_start.sh with all fixes: 83 PASS, 0 FAIL (pc/_test/review2/start_full.log).
  STARTEN.md: password step says "meteen daarna" + sudo gives up after minutes. status.py "clone"->"kloon".
  Running now: test_thinning + test_sweep_kill (tool_env change) -> pc/_test/review2/{thin,sweepkill}.log;
  then re-run sim scenarios A, B, CD, N, P on the final code; then report.
- [stap 6] regression: test_thinning PASS; test_sweep_kill 1st run 1 FAIL = timing flake (the engine had already
  finished its 6-s chunk when the test killed it: "kill: No such process"), 2nd run ALL PASS. Final re-run of
  sim scenarios A, B, CD, N, P on the final code: ALL PASS (pc/_test/review2/scen*.final.log). bash -n on all
  .sh, py_compile on all .py, setup --test-functies 0 errors. Test run data deleted (logs kept). REVIEW DONE.
  Not fixable in pc/ (for the main session): permission prompts in the app (user decision: allowlist in
  .claude/settings.json or --permission-mode), git push credentials on the workstation, merge the lifeB engine
  keys into engine/ + engine_gpu/ before production.ini uses them.
