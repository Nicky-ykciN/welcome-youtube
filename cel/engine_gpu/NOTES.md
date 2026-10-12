# engine_gpu NOTES (crash-safety log)

Task: CUDA port oercel_gpu of engine/oercel.c (+ memB_src lipid-architecture extensions),
single source that also compiles as plain C++/OpenMP ("emulation mode").

## Status
- [ ] read engine/oercel.c, README, memB diff
- [ ] write oercel_gpu.cu
- [ ] emulation build + tests
- [ ] nvcc install + sm_75 compile
- [ ] selftest_gpu.sh, README.md

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
