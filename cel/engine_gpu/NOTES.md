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
