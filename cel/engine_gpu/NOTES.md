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
