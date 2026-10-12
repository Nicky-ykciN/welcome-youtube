# engine_gpu NOTES (crash-safety log)

Task: CUDA port oercel_gpu of engine/oercel.c (+ memB_src lipid-architecture extensions),
single source that also compiles as plain C++/OpenMP ("emulation mode").

## Status (keep this block current)
DONE. Everything that can be tested without a GPU is tested; see README.md "Tests".
- [x] oercel_gpu.cu (CUDA + emulation single source), Makefile; nvcc 12.0 -arch=sm_75 compiles clean
- [x] emulation vs reference: forcetest, water, bonds (incl. high-statistics + block errors), vesicles
      (teamA L=64 2 seeds x 60k), chemistry (soup + chemstat), determinism, restart identity, SIGTERM
      chunks, cross-engine ckpt, feedcheck, stirring, kT cycle, pi/y lipids vs memB, L=1024 smoke,
      analyze.py/render.py
- [x] selftest_gpu.sh (+ --emu mode), setup_wsl.sh, run_bg.sh, README.md
- [ ] (needs the GPU machine) ./setup_wsl.sh && ./selftest_gpu.sh
How to re-check after a crash: `cd engine_gpu; make emu; make test; ./selftest_gpu.sh --emu --quick --only "1 2"`
(1 thread per engine). nvcc here: /usr/bin/nvcc (apt nvidia-cuda-toolkit 12.0, installed by me).

## Log
- step 0: created dir.
- step 1 (02:20): read engine/oercel.c (md5 f760b805...), memB diff (md5 88439df6...), README, tests.
  pip wheels nvidia-cuda-nvcc-cu12 (12.4, 12.9) contain only ptxas+libnvvm, NO nvcc driver -> unusable.
  developer.download.nvidia.com is blocked by egress policy (403). apt nvidia-cuda-toolkit 12.0
  (Ubuntu noble multiverse, 1.6 GB) installing in background; log in scratchpad apt_cuda.log.
  Design decided (see README.md when written): double x,y,vh,f; float4 force input (cell-local
  coords + vt); full-neighbour pair kernel (exactly antisymmetric pair force, double accumulation);
  deterministic local "gather-by-cell" stable sort each step (+ host stable counting sort fallback);
  bonded = 1 thread per molecule (no atomics); chemistry on device: active catalysts drawn by
  counter hashes, executed in priority order via cell-lock rounds (= exact serial semantics);
  decay/feed per-bead hashes identical to reference; feed cap subset by smallest hash keys.
- step 2 (02:35): apt nvidia-cuda-toolkit 12.0.140 installed OK (/usr/bin/nvcc, uses g++-12 automatically).
  Verified pattern compiles for sm_75: static host fn + `[=] __device__` lambda capturing a struct
  -> template __global__ k_pfor; __constant__ must be declared in BOTH nvcc passes (#ifdef __CUDACC__),
  only the access macro switches on __CUDA_ARCH__. Next: write oercel_gpu.cu.
- step 3 (02:40): oercel_gpu.cu written (~1950 lines), Makefile (make / make emu / make test).
  Both builds compile cleanly (nvcc 12.0 -arch=sm_75: pair kernel 50 regs no spill; chem exec 95 regs
  2.7 KB stack). --forcetest PASS in emulation for L=9,12.5,23.7 and lip_arch pi/y/bola:
  pair vs O(N^2) double brute force max err ~4e-5 (float), sum F == 0 exactly (antisymmetric pairs +
  TwoSum; needed __fmul_rn on GPU and -ffp-contract=off on host), local-gather sort R=1..4 + full sort OK.
  Bug found+fixed: TwoSum broken by FMA contraction. ref/ holds frozen copies of the reference sources
  (engine md5 f760b805, memB md5 88439df6); build/ has their binaries; testruns/ = my test outputs.
  NEXT: water box T/P/g(r) vs reference, restart determinism, soup L=64 teamA 2 seeds x 50k.
- step 4 (02:45): emu step-0 snapshot of a teamA soup is BITWISE identical to the reference (same init
  RNG stream); params.ini identical except the 6 memB keys. Water L=32 2000 steps: p ~1e-13 (exact).
  Launched in background: tests/run_soup_compare.sh ./oercel_emu testruns/soupA_emu 60000 1 1 2
  (teamA physics, L=64, seeds 1,2, 60k steps, snaps every 2000). Reference runs to do after.
- step 5 (02:41): RESULT teamA soup L=64 60k steps (testruns/soupA_{ref,emu}_s{1,2}), tools/analyze.py:
  closed vesicles last snapshot ref 3,2 / emu 4,4; mean last third ref 2.5,1.6 / emu 2.9,1.3 -> PASS
  (series: first vesicles ref 22k/30k, emu 24k/36k steps). Bonds: mean 0.5467 vs 0.5474, std 0.1008 vs
  0.1009; <T> 0.9896 vs 0.9891; T-neighbour fraction 0.845 vs 0.844. Emu speed 1 thread ~5.4 ms/step
  vs ref 1.0 ms/step at L=64 (loaded machine).
  Written: tests/compare.py (water/bonds/vesicles/chem/ident), tests/run_soup_compare.sh,
  setup_wsl.sh (WSL2 prerequisites + nvcc via NVIDIA redist tarballs, untested here: host blocked),
  selftest_gpu.sh (11 sections; --emu mode runs the same checks with oercel_emu).
  NEXT: run selftest_gpu.sh --emu --quick to debug the script, then full-length sections.
- step 6 (02:46): selftest_gpu.sh --emu --quick --only "1 2": 13/13 PASS (forcetests incl. L=64.3,
  determinism ident: stats/events(9010 rows)/snapshots/ckpt identical). Fixed: parity sed, section 11
  guard, adaptive SIGTERM timing in section 6, script now re-execs from a private temp copy (editing a
  running bash script corrupted a run; also never `pkill -f` a pattern that matches your own shell).
  Running in background: selftest --emu --quick --only "3 5 6 7" -> testruns/selftest_emu_q3567.txt
- step 7 (02:50): README.md written (design, parity table, tests, untested list, perf estimate).
  Emu selftest section 3 (water L=64, 10k steps quick): <T> 0.9962+-0.0006 vs ref 0.9967+-0.0006,
  max|P| 1.2e-12, g(r) peak 1.080@0.85 vs 1.077@0.85 (max diff 0.0055), virial pressure 29.500 vs
  29.500 -> all PASS. Sections 5,6,7 still running (testruns/selftest_emu_q3567.txt).
- step 8 (03:05): BUG in selftest: bare `wait` hangs in bash 5.2 because it also waits for the
  `exec > >(tee ...)` process substitution -> now `wait $bgpid`. compare.py chem accepts run lists
  and compares syn/rep per catalyst-check (seed 1 soup_small 15k: syn/Kcheck 1.13e-3 vs ref 1.33e-3,
  z=-1.3; rep 6.57e-4 vs 6.67e-4). New tests/chemstat.sh (well-mixed chem statistics + mutation
  fraction). Relax neighbour collection optimised (bbox of cells, fallback to reference loop in tiny
  boxes) -> built as build/oercel_emu_new (not yet tested; selftest 5-7 still running on old binary).
- step 9 (03:15): emu selftest --quick sections 5/6/7: chem (2 seeds x 15k, soup_small p_rep_a 1.5e-3):
  syn/Kcheck gpu 1.084e-3 vs ref 1.231e-3 (z=-1.4), rep 5.9e-4 vs 6.7e-4 (z=-0.95), dK/dN/dlip/mut
  match; feed total "FAIL" was a bad test (with binding cap, feed == consumption: balance 816 vs 817,
  972 vs 973) -> compare.py now reports the balance instead. Section 6: restart 300 -> identical
  stats/1565 events/snapshots/ckpt; 2 SIGTERM interruptions + restarts identical to uninterrupted.
  Section 7: CPU ref continues from GPU ckpt: PASS. pair noise now int32->float (top 32 bits).
- step 10 (03:35): new emu binary (relax bbox + int32 noise). tests/chemstat.sh (L=48 well-mixed, 20k
  steps): synthesis-only: syn/Kcheck 1.594e-3 vs ref 1.623e-3 (660 vs 672 events, z=-0.3);
  replication-only: (rep+mut)/Kcheck 2.15e-3 vs 2.20e-3; mutation fraction gpu 0.275+-0.018,
  ref 0.344+-0.018 (mu=0.3); extra run gpu 0.305+-0.029, ref 0.276+-0.025. Hash independence of
  rep/mut decisions verified directly in numpy: 0.2997+-0.0019. -> chemistry statistically OK.
  Running: selftest --emu --quick --only "2 4 8 9 10" -> testruns/selftest_emu_q248910.txt
- step 11 (03:10): emu selftest q "2 4 8 9 10" running. Section 2 determinism PASS (8792 events).
  Section 4 (soup_small chem=0, 20k steps, only 6 snapshots = 5526 bonds): bond mean 0.5417 vs ref
  0.5449 (1.7 sigma) -> old fixed 0.5% limit FAILed; limit now max(0.2%, 4 standard errors) and 20
  snapshots per run; <T> 0.9925 vs 0.9929, T-neighbour 0.795 vs 0.798, max bond 1.087 vs 1.087.
  TODO: extra high-statistics bond test (many snapshots) to rule out a systematic bond-length shift.
  Added run_bg.sh (background start/continue with nohup; tested start + continue).
- step 12 (03:08): emu selftest section 8 quick (teamA L=64, 30k steps, 2 seeds x 2 engines):
  analyze.py OK on all 4; closed vesicles mean(last third) gpu 0.6,0.4 vs ref 0.6,0.2 (few vesicles
  this early, as in the 60k runs where they appear at 22-36k); bonds 0.5465 vs 0.5471 (27630 bonds),
  <T> 0.9893 vs 0.9897, T-neighbour 0.837 vs 0.835; render.py micro OK. Section 9 running.
  Section 9 feedcheck: all PASS (uniform 1138 conversions = exactly the reference README's 1138,
  since feed decisions use the same hashes; cap 345 = floor(0.05 N); vent disk/vstrip/hstrip exact).
- step 13 (03:10): section 9: stirring u0 0.2516 (pooled err 0.005) vs reference rerun here 0.2660
  (pooled 0.005, but per-checkpoint scatter gives sem 0.0088 -> pooled error underestimates; diff is
  ~1.2 sigma) -> selftest check now uses per-checkpoint sem and z<4. kT cycle: 0.9961 + 0.1951
  sin(.. - 0.110) vs reference README 0.9953 + 0.1961, lag 0.10. Section 10 running.
- step 14 (03:12): emu selftest q "2 4 8 9 10" finished: 42 PASS, 1 FAIL (the section-4 bond mean with
  the old fixed 0.5% limit; 1.7 sigma, the new statistical criterion passes it). Section 10: pi lipids
  bonds 0.6089 vs 0.6088, max 1.256 vs 1.254, syn/Kcheck 1.93e-2 vs 2.03e-2 (syn_nN=2 path);
  y lipids bonds 0.5551 vs 0.5556, syn/Kcheck 1.80e-2 vs 1.87e-2. Final emu/gpu binaries rebuilt.
  NEXT: high-statistics bond test, L=1024 big-box smoke test, README/NOTES final.
- step 15 (03:16): high-statistics bonds (soup_small chem=0, 77 snaps, 70917 bonds): 0.5429 vs 0.5439;
  block errors (per-snapshot means are correlated, lag-1 ~0.6) give -0.0010 +- 0.0023; combined over
  the 3 long comparisons -0.0006 +- 0.0005 (z=-1.2) -> no significant shift. compare.py bonds now uses
  block errors. L=1024 (3.1M beads) smoke: step-0 snapshot bitwise identical to the reference; after
  20 steps max bond 1.359395/1.279218 and T 2.32218 identical to the reference to 5-7 digits.
  make test (emu): 6/6 FORCETEST PASS. README final (results, requests, emulation run table).
- step 16 (03:20): final script rerun selftest --emu --quick --only "9 10": 38/38 PASS (stirring now with
  per-checkpoint errors: 0.2516+-0.0070 vs ref 0.266+-0.009, z=-1.28; identical u0 to the earlier emu
  run = deterministic across invocations). Final source md5 ffccdd72. DONE; report returned.

## REVIEW (independent reviewer/fixer, started 2026-10-12 ~03:30) -- keep this block current
Scope: review oercel_gpu.cu + scripts (races, atomics, noise symmetry, PBC, sort, overflow, chemistry
conflicts, events, ckpt, memory, launch checks, GPU vs emu divergence); fix in place; re-run emu tests.
Rules: only files in engine_gpu/; max 1-2 threads; short tests; no git.
Backup of the original source before any review edit: build/review_orig_oercel_gpu.cu (md5 ffccdd72).
- R0: read oercel_gpu.cu fully + reference engine/oercel.c (sort, forces, chemistry, ckpt, main loop) + memB diff.
- R1 (03:50) FINDING A (reference bug, not fixable here): CPU reference restarting from a GPU ckpt gets
  scrambled forces for one step: engine/oercel.c main() calls sort_cells() at restart assuming identity,
  but sort_cells does not permute fx/fy; GPU ckpt is in GPU (row-major) slot order -> T jumps
  1.036 -> 1.169 at the first step (test: scratchpad rv/xg2r). GPU<-CPU direction is exact (6 digits).
  Selftest section 7 only checked mean T -> did not see it. Request for engine/: permute fx,fy with
  s->src after the restart sort.
- R2 (03:55) added test oracle OERCEL_CHEM_SERIAL=1 (plain serial loop in priority order). High-conflict
  emu run (L=32, c_N .3, f_K .06, p_syn .5/.8, p_rep .3, 1200 steps, 7043 events): lock rounds vs serial
  -> stats/events/snapshots/ckpt BITWISE IDENTICAL. Lock scheme confirmed. Perf note: in that dense
  small box 191603 actives took 161412 rounds (emu 119 s vs serial 1.7 s): rounds ~ conflicts; fine
  for production densities (author: 688 actives / 7 rounds at L=1024).
- R3 fixed relax_new_chain fast path: ex/ey now re-minimum-imaged (small boxes could miss neighbours).
- R4 (04:05) new tool ckpt_to_cpu.py: re-sorts a GPU ckpt into the CPU engine's slot order (stable by
  ref cell key, nsub) -> REF restart from converted GPU ckpt matches the emu continuation to 6 digits
  (T 1.035996, 1.036562, ...); a REF ckpt passes through unchanged (identity -> key formula exact).
  OERCEL_CHEM_SERIAL oracle now uses pfor_dyn (32 threads; 88 regs would fail at OERCEL_TPB=1024).
  nvcc 12.0 sm_75 still compiles: 0 spills (build/rv_ptxas.txt).
- R5 (03:50 real clock) selftest: section 2 now also runs OERCEL_CHEM_SERIAL=1 and requires bitwise
  identity with the lock rounds; section 7 now checks the first 5 steps after GPU->CPU switch (PASS
  with ckpt_to_cpu.py, WARN (not counted) for the unconverted file until engine/ is fixed); summary
  greps FAIL|WARN. Emu --quick "2": all PASS incl. serial oracle (8792 events identical).
  run_bg.sh: engine now started with `nohup setsid` (own session; PID unchanged; tested start,
  SIGTERM stop with ckpt, continue). Engine log now prints sort diagnostics (max R, host full sorts).
  Originals kept in build/review_orig_*.
- R6 (03:58) review edits verified physics-neutral: original source (build/review_orig_oercel_gpu.cu)
  vs current, det config L=64 (8792 events) and small boxes L=9/10/12 with pi lipids: stats/events/
  snapshots/ckpt bitwise identical -> all of the author's emulation statistics stay valid. (The relax
  minimg bug needs a tiny box AND a long lipid with bead 0 at the end; not triggered in these runs.)
  ckpt_to_cpu.py also verified for memB v3 (pi lipids): memB CPU continuation of the converted GPU
  ckpt = GPU continuation (T 1.046784, 1.041257, ...); unconverted: T 1.1449 at the first step.
  README updated (switching to CPU engine, OERCEL_CHEM_SERIAL, request 5, selftest table). Original
  README in build/review_orig_README.md. Running: selftest --emu --quick --only "1 6".
- R7 (04:00) final checks on the current source (md5 6a266b4d): nvcc 12.0 sm_75 compiles clean, 32 kernels,
  0 spills (build/rv_ptxas.txt); oercel_gpu + oercel_emu rebuilt; make test (emu) 6/6 FORCETEST PASS;
  selftest --emu --quick "1 6": 15/15 PASS (forcetests all L/arch, restart identity, 2 SIGTERM chunks).
REVIEW STATUS: DONE. Findings + fixes summarised in the report to the orchestrator; README updated.
  Open (outside engine_gpu/): engine/oercel.c + runs/memB_src/oercel.c restart must permute fx,fy
  (README request 5); pc/longrun.py --forceer-engine / --van-ckpt GPU->CPU should run ckpt_to_cpu.py
  until then. Untestable here: everything on a real GPU / WSL2 (run ./setup_wsl.sh && ./selftest_gpu.sh).
