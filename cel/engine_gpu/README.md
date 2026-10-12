# oercel_gpu — the Oercel engine on an NVIDIA GPU

`oercel_gpu` is a CUDA port of the reference engine `engine/oercel.c` (2D DPD with local
stochastic chemistry, SPEC.md), including the lipid-architecture extension of
`runs/memB_src/oercel.c` (`lip_arch`, `r0_head`, `k_head`, `cos_head`, `lip_tie`, `syn_nN`).
It is a **drop-in replacement**:

- same command line: `oercel_gpu params.ini outdir [key=value ...]`, `--params`;
- same ini parameters, defaults and meaning: `--params` prints the reference's table plus the six
  memB keys;
- same output files: `snap_<step>.bin`, `stats.csv`, `events.csv`, `params.ini`, `log.txt`, and
  `ckpt.bin` in the reference checkpoint format (version 2; memB version 3 for non-linear lipids).
  `tools/analyze.py` and `tools/render.py` work unchanged on its output (tested);
- checkpoints are interchangeable **in both directions** (tested): oercel_gpu continues a CPU
  checkpoint exactly; the CPU engine continues a GPU checkpoint exactly **after**
  `python3 ckpt_to_cpu.py ckpt.bin ckpt_cpu.bin` (see "Switching a run to the CPU engine").

It is the same SPEC §0 world: only pair laws, bonds, local stochastic reactions and
structure-blind environmental physics. Nothing in the port knows about cells or membranes.

One source file, `oercel_gpu.cu`, builds two ways:

| build | command | runs on |
|---|---|---|
| CUDA | `make` (nvcc, default `ARCH=sm_75` = Quadro RTX 8000 / Turing) | the GPU |
| CPU emulation | `make emu` (g++ + OpenMP, no CUDA needed) | the CPU, **same kernel bodies** |

**Status.**
- The CUDA build compiles cleanly for sm_75 (nvcc 12.0).
- Everything was tested in the emulation build, which runs the very same kernel code, against
  the CPU reference engine (see "Tests").
- Nothing could be run on a real GPU or in WSL2 here (no GPU on the development machine).
  `selftest_gpu.sh` does that on the target machine.

## Quick start on the GPU machine (WSL2 Ubuntu)

```bash
cd cel/engine_gpu
./setup_wsl.sh          # checks GPU/driver, installs what is missing (g++, python3 modules, nvcc), builds oercel_gpu
./selftest_gpu.sh       # ~10-20 min: PASS/FAIL per check + ms/step at L = 128, 256, 512, 1024
./run_bg.sh ../notes/membranen/teamA_membranes.ini ../runs/gpu_teamA_L512 L=512 steps=300000 snap_every=5000
tail -f ../runs/gpu_teamA_L512/log.txt
```

**`setup_wsl.sh`** (idempotent; `--check` only reports):
- The GPU driver comes from **Windows**: WSL2 exposes it as `/usr/lib/wsl/lib/libcuda.so` and
  `nvidia-smi`. Never install a Linux NVIDIA driver inside WSL2. If `nvidia-smi` fails, update
  the Windows driver (≥ 525), then run `wsl --shutdown`.
- `g++`, `make`, python3 + numpy/scipy/matplotlib/pandas/PIL and ffmpeg come from apt. If sudo
  needs a password and there is no terminal, the script prints the single `apt-get` line to run
  once by hand.
- If no `nvcc` exists, the CUDA 12.6 compiler, runtime and headers are downloaded from NVIDIA's
  redistributable archives into `engine_gpu/.cuda`: no sudo, nothing system-wide. Set
  `CUDA_REDIST_VERSION` for another 12.x release.
- If that build fails, the script falls back to NVIDIA's official WSL-Ubuntu apt repository
  (`cuda-toolkit-12-6`, needs sudo).
- Ubuntu's own `nvidia-cuda-toolkit` package is avoided on purpose: in WSL2 it pulls in Linux
  driver libraries whose `libcuda.so` can shadow the WSL one.

**`run_bg.sh params.ini outdir [key=value ...]`** starts the run with nohup, so it survives the
terminal or the Claude session.
- If `outdir/ckpt.bin` exists, it continues from there.
- Console output goes to `outdir/console.txt`.
- `kill $(cat outdir/engine.pid)` stops cleanly with a checkpoint.

## Build options

```bash
make                         # oercel_gpu for sm_75
make ARCH="sm_75 sm_86"      # several architectures (+ PTX of the last one, for newer GPUs)
make NVCC=/path/nvcc CCBIN=g++-12
make emu                     # oercel_emu (CPU emulation)
make test                    # --forcetest of the builds that exist
make check-cuda              # compile with register/stack report
```

- nvcc older than 12.4 needs gcc ≤ 12. The Makefile switches to `g++-12` automatically when
  that applies and `g++-12` exists.
- The host side is compiled with `-ffp-contract=off`, and the device side uses `__fmul_rn` in the
  force accumulation.
- **Never** add `-ffast-math` or `--use_fast_math`: exact momentum conservation relies on IEEE
  rounding (see "Pair forces").

## Running

Exactly like the reference engine. `engine/README.md` documents every parameter, chunked runs,
restarts and the file formats. Differences:

- `threads` sets the OpenMP threads for host-side work (snapshot assembly). In the emulation
  build it is the kernel thread count.
- `nsub` is accepted and ignored. It is a CPU-only performance knob, with the same physics.
- Environment variables, all optional:

  | variable | effect |
  |---|---|
  | `CUDA_VISIBLE_DEVICES` | choose the GPU |
  | `OERCEL_PROFILE=1` | synchronise after each phase, so the final `timing:` line splits the time correctly (slightly slower) |
  | `OERCEL_SYNC=1` | synchronise after every kernel (debugging: pinpoints a failing kernel) |
  | `OERCEL_TPB`, `OERCEL_PAIR_TPB` | threads per block for all kernels / the pair kernel (default 256) |
  | `OERCEL_CHEM_SERIAL=1` | test oracle: run the reactions as the plain serial loop in priority order instead of the parallel cell-lock rounds (slow; the result must be bitwise identical, selftest section 2) |

- `--forcetest [L] [lip_arch]` runs the kernel self-test; `--version` prints the build type.
- **Sizes:**
  - GPU memory: ≈ 160 bytes per bead + 16 bytes per cell, so 48 GB holds ≈ 250 M beads
    (L ≈ 9000). The engine checks free GPU memory at start.
  - Hard limit: N < 2²⁹ (5.4·10⁸).
  - Host RAM at start or restart: ≈ 120 bytes per bead (6 GB at L = 4096).
  - A snapshot is 9 bytes per bead plus bonds: 450 MB at L = 4096. Choose `snap_every` accordingly.
- Long runs: `steps` is absolute. SIGTERM, SIGINT and `walltime` stop cleanly with a checkpoint,
  and `restart=outdir/ckpt.bin` continues bitwise identically (tested), as with the CPU engine.
- If the GPU engine is ever wrong, the CPU engine can continue from its last checkpoint (convert
  it first, see below), and vice versa.
- The final log lines report the timing per phase, the chemistry rounds and the cell sort
  (largest per-step cell displacement; number of host-side full sorts, which should stay at 1 =
  the start).

### Switching a run to the CPU engine

A checkpoint stores the per-bead arrays in the writing engine's slot order. When
`engine/oercel.c` restarts, it re-sorts the beads into its own cell order but does not carry
the stored forces `fx, fy` along (it assumes the file is already in its order). A GPU
checkpoint is in the GPU's order, so without conversion the CPU engine's first step uses forces
that belong to other beads (measured: T jumps from 0.99 to 1.12 for that step, then relaxes).
Therefore:

```bash
python3 engine_gpu/ckpt_to_cpu.py runs/X/ckpt.bin runs/X/ckpt_cpu.bin   # --nsub N if the CPU run uses nsub != 4
engine/oercel params.ini runs/X restart=runs/X/ckpt_cpu.bin
```

`ckpt_to_cpu.py` only re-orders the file (stable sort by the CPU engine's cell index, nxt links
remapped); a CPU checkpoint passes through unchanged. With it the CPU continuation matches the
GPU's own continuation to all 6 printed digits of T for the first steps (selftest section 7).
The other direction needs nothing: oercel_gpu carries the forces through its restart sort. Once
`engine/oercel.c` permutes `fx, fy` at restart (request 5 below), the conversion is unnecessary
but harmless.

## Feature parity

| feature (reference / memB) | oercel_gpu |
|---|---|
| DPD conservative + dissipative + random force, symmetric counter-based pair noise θ(seed, step, min gid, max gid) | yes; the same hash (top 32 bits), evaluated in single precision |
| Groot–Warren integrator (λ, stored half-step velocity) | yes, the same update in double precision |
| harmonic bonds and angle terms; memB templates linear / pi / y / bola with `k_head`/`cos_head` junction terms and `lip_tie` rungs | yes (template in constant memory); bonded forces in double precision |
| warm-up ramp of a_ij > 25 | yes |
| `init = soup` | yes, on the host with the reference's RNG stream: **the step-0 snapshot is bitwise identical to the reference's** |
| chemistry: lipid synthesis (`syn_tries` orientation search, `syn_relax` relaxation, mean velocities, memB `syn_nN` with W beads), replication + mutation, lipid / catalyst / nutrient decay | yes, all on the GPU (see "Chemistry") |
| food supply `uniform` / `vent` (disk, vstrip, hstrip), `feed_cap` | yes; feed and decay decisions use the **same hash keys** as the reference |
| event log (`syn rep mut dlip dK dN feed`) | yes, same columns and formatting; the order within a step is deterministic but differs from the reference |
| stirring (Kolmogorov force, net force removed), temperature cycle kT(t) | yes |
| restart, `restart_reseed`, `walltime`, signals, `ckpt_keep`, params-change detection, csv truncation on restart | yes |
| checkpoint v2 (linear) / v3 (memB architectures) | read and write, interchangeable with the CPU engines |
| removed features (`init = seeded`, flood-fill feed) | same explicit errors |

Not ported: the AVX-512 code path (CPU only).

## Design

**Layout.** All per-bead state lives on the device in "slot" order and is re-sorted by cell
every step.
- Cells are ≥ 1 wide (`ncx = ncy = floor(L)`, row major).
- State is double precision: x, y, the half-step velocity vh and the force f.
- The pair kernel reads a `float4` (x and y relative to the bead's own cell corner, plus the
  predicted velocity ṽ) and one `uint32` (gid | type ≪ 29).
- So the pair arithmetic is single precision (the RTX 8000 has 1/32-rate FP64), but positions
  keep full resolution at any box size.
- The only device→host copy per step is a 40-byte status record (the sort radius).
- Snapshots and checkpoints are assembled on the host.

**Sort (every step, deterministic).**
- New cells are counted with integer atomics (order independent), and an exclusive scan gives
  the cell starts.
- Then one thread per *new* cell gathers its beads by scanning the old cells within R cells, in
  increasing old-slot order. R is the largest cell displacement since the last sort: 1 normally,
  up to 4 after a synthesis re-placed beads.
- The result is exactly the stable counting sort, without atomics on positions.
- If R > 4, or at start and restart, a host-side stable counting sort gives the same permutation.

**Pair forces.**
- One thread per bead visits the 3×3 neighbour cells. This is a full neighbour list without
  Newton's third law: no atomics, and a fixed summation order per bead.
- Both threads of a pair compute bit-identical magnitudes, and dx_ji = −dx_ij exactly
  (fl(a−b) = −fl(b−a)), so F_ji = −F_ij exactly.
- Each bead's sum uses compensated (TwoSum) single-precision accumulation and is stored in double.
- Result: Σ F = 0.0 exactly without stirring (≤ 10⁻¹⁰ with stirring), and total momentum stays at
  10⁻¹³–10⁻¹², like the reference.

**Bonded forces.** One thread per molecule head (each bead belongs to exactly one molecule), so
there are no atomics. The template comes from memB `mol_t`, in double precision. The maximum
bond length uses a max-atomic, which is order independent.

**Stirring.** The force is a float sine after a double range reduction (error ≈ 10⁻⁷). Its net
force is removed by a deterministic reduction.

**Reductions** (stirring mean, temperature, momentum, type counts, nN) use a fixed partition
(16384 strided partial sums, then 64, then the host). Results are therefore reproducible for any
device and thread count.

**Chemistry (on the GPU).** One check runs reactions, then decay, then feed, as in the reference.
- **Reactions.**
  - Each catalyst decides from counter-based hashes of (seed, step, gid) whether it attempts
    synthesis and/or replication. The reference uses its serial RNG; the probabilities are the
    same.
  - The few *active* catalysts get a random priority (another hash; the short list is sorted on
    the host).
  - They are executed in rounds. Each active catalyst claims (`atomicMin` of its rank) every cell
    within RL of its own cell. A catalyst whose claims all hold its own rank executes the full
    reference reaction body in one GPU thread: neighbour search sorted by (distance, gid),
    orientation search, relaxation, mean velocities, events.
  - RL covers the cells whose slots a reaction can write plus the cells it can read (search
    window, overlap and relax windows around the new bead positions). So reactions in the same
    round cannot see each other, and each reaction runs after every lower-ranked reaction within
    its reach.
  - The outcome is therefore **exactly the serial loop in priority order**, whatever the
    parallel schedule. The number of rounds is about the largest number of simultaneously active
    catalysts in one neighbourhood (measured: 1376 rounds for 2068 reactions over 1500 checks in
    `soup_small`).
- **Decay and feed** are per-bead decisions with the reference's own hash keys (salts 11–14).
  - With the same configuration they make the same decisions as the reference.
  - The `feed_cap` subset is the `room` candidates with the smallest hash keys: uniformly random
    and order independent. Only these candidate keys (≈ p_feed·N_W·8 bytes) go to the host.
- **Events** are appended on the device with a sort key (phase, priority rank or slot) and
  written sorted.

**Determinism.**
- For a fixed build and device, a run is a deterministic function of its parameters, and in
  emulation independent of the thread count (tested bitwise).
- It is **not** bitwise identical to the CPU reference, because the pair forces are single
  precision. It is statistically equivalent; see "Tests".

## Tests

### Done on the development machine (4-core VM, no GPU): CPU-emulation build + `nvcc -arch=sm_75` compile

**CUDA compile.** nvcc 12.0 (Ubuntu package), `-arch=sm_75`: clean, no warnings, 0 spills in 31
kernels.
- Pair kernel: 45 registers.
- Bonded kernel: 58 registers, 240-byte stack.
- Chemistry execution: 95 registers, 2.9 KB stack (one thread per reacting catalyst).
- Kernel parameters ≤ 1.3 KB.

**Emulation tests.** All numbers below come from the emulation build, which runs the same kernel
bodies. "Reference" is `engine/oercel.c`; its frozen copy is `ref/oercel_ref.c`.

| test | result |
|---|---|
| `--forcetest` L = 9, 12.5, 23.7, 64.3 (wrap-around, non-integer cell size) | pair forces vs double-precision O(N²) brute force: max \|ΔF\| 3.7·10⁻⁵–2.7·10⁻⁴ (max \|F\| 112–320); Σ F = 0.0 exactly (≤ 6·10⁻¹¹ with stirring); bitwise identical on repetition and with 1 vs 2 threads |
| `--forcetest` sort | local gather sort with R = 1, 2, 3, 4 and the full-sort fallback: 0 errors in chains, cells and the permutation |
| `--forcetest` bonded | linear, pi, y, bola (with junction terms and rungs) vs finite differences: rel. error ≤ 8·10⁻⁶ |
| noise | mean 0.0012, variance 1.0009, lag-1 correlation 0.0004, symmetric; float θ vs double θ ≤ 1.4·10⁻⁷ |
| step-0 snapshot of a soup | **bitwise identical** to the reference engine's |
| determinism (all reactions, capped feed, stirring, kT cycle) | two runs: stats, ≈ 9000 events, snapshots and checkpoint bitwise identical |
| restart at step 300 (3 → 1 thread) | the continuation is bitwise identical (stats, 1565 events, snapshots, ckpt) |
| run killed twice by SIGTERM + restarted into the same directory | stats.csv, events.csv, final snapshot and ckpt identical to the uninterrupted run |
| checkpoint GPU → CPU reference and CPU reference → GPU | both continue; ⟨T⟩ 0.998 / 1.000; max bond 0.99 / 1.08. Review: CPU → GPU matches the reference's own continuation to 6 digits; GPU → CPU does so only after `ckpt_to_cpu.py` (unconverted: first-step T 1.12 instead of 0.99, see "Switching a run to the CPU engine") |
| parallel chemistry vs serial oracle (`OERCEL_CHEM_SERIAL=1`), review | dense small box (L = 32, 6 % catalysts, p_syn 0.5/0.8, p_rep 0.3, 1200 steps, 7043 events) and selftest section 2 (8792 events): stats, events, snapshots, ckpt **bitwise identical** to the strictly serial loop |
| water L = 64, dt = 0.03, 300 t.u. | ⟨T⟩ 0.9962 ± 0.0006 vs reference 0.9967 ± 0.0006; max\|P\| 1.2·10⁻¹² (reference 1.6·10⁻¹²); g(r) first peak 1.080 at r = 0.85 vs 1.077 at 0.85, max \|Δg\| 0.0055; virial pressure 29.500 ± 0.011 vs 29.500 ± 0.006 |
| teamA membrane physics, L = 64, 60 000 steps, seeds 1 and 2, `tools/analyze.py` | closed vesicles at the last snapshot: reference 3, 2 / emulation 4, 4. Mean over the last third of the snapshots: 2.5, 1.6 / 2.9, 1.3. First vesicle at 22k / 30k vs 24k / 36k steps |
| same runs: bonds and aggregation | bond length mean 0.5467 vs 0.5474, std 0.1008 vs 0.1009 (55 260 bonds each); ⟨T⟩ 0.9896 ± 0.0008 vs 0.9891 ± 0.0008; T-neighbour fraction 0.845 vs 0.844 |
| `tools/render.py --kind micro` on the emulation run | works: membranes enclosing N-rich lumens with catalysts, as described in teamA_TUNING.md |
| chemistry, well-mixed (`tests/chemstat.sh`, L = 48, 2000 checks) | synthesis per catalyst-check 1.594·10⁻³ vs 1.623·10⁻³ (660 vs 672 events, z = −0.3); replications per catalyst-check 2.15·10⁻³ vs 2.20·10⁻³; mutation fraction 0.275 ± 0.018 and 0.305 ± 0.029 vs 0.344 ± 0.018 and 0.276 ± 0.025 (μ = 0.3); hash independence of the rep/mut decisions checked directly: 0.2997 ± 0.0019 |
| chemistry in `soup_small` (2 seeds × 15 000 steps) | syn per catalyst-check 1.08·10⁻³ vs 1.23·10⁻³ (z = −1.4); rep 5.9·10⁻⁴ vs 6.7·10⁻⁴ (z = −0.95); dK 107/103, dN 469/453, dlip 176/195; feed = nutrient consumption (balance exact in both) |
| lipid soup without chemistry (`soup_small`, L = 64, 20 000 steps) | ⟨T⟩ 0.9925 vs 0.9929; T-neighbour fraction 0.795 vs 0.798; max bond 1.087 vs 1.087; bond length 0.5417 vs 0.5449 from only 6 snapshots. That failed the first, too tight fixed limit; with honest errors it is within 1σ, see the high-statistics row |
| teamA L = 64, 30 000 steps (selftest `--quick`), 2 seeds × 2 engines | `tools/analyze.py` accepts all four runs; closed vesicles, mean over the last third: 0.6, 0.4 vs 0.6, 0.2 (this early only 0–1 vesicles in both); bonds 0.5465 vs 0.5471 (27 630 bonds); ⟨T⟩ 0.9893 vs 0.9897 |
| food supply (`engine/tests/feedcheck.py`) | all checks PASS: uniform 1138 conversions (identical to the reference's own validation, because the decisions use the same hashes), chi² 37.7/35; cap 0.05 → max nN 345 = floor(cap·N); vent disk / vstrip / hstrip: every conversion inside (max 4.9966 < 5, 1.9995 < 2, 1.4995 < 1.5) |
| stirring, water L = 48, A = 0.0015 | u0 = 0.252 vs 0.266 for the reference rerun here with the same procedure. The per-checkpoint scatter gives ±0.009 per run, so the difference is 1.2σ. ν = 0.35 vs 0.33; max\|P\| 1.9·10⁻¹² |
| temperature cycle kT = 1 + 0.2 sin(2πt/30) | T_kin = 0.9961 + 0.1951 sin(2πt/30 − 0.110) (reference 0.9953 + 0.1961, lag 0.10) |
| pi lipids (`lip_nT=2 lip_tie=1 r0_head=0.7 k_head=5`, synthesis with `syn_nN=2`) vs the memB CPU engine | bond length 0.6089 vs 0.6088, std 0.1171 vs 0.1161; max bond 1.256 vs 1.254; ⟨T⟩ 0.9958 vs 0.9943; T-neighbour fraction 0.744 vs 0.748; syn per catalyst-check 1.93·10⁻² vs 2.03·10⁻² (z = −1.1) |
| y lipids (`lip_nT=2 k_head=5 cos_head=0.3`, `syn_nN=2`) vs the memB CPU engine | bond length 0.5551 vs 0.5556, std 0.1004 vs 0.1008; ⟨T⟩ 0.9995 vs 0.9983; T-neighbour fraction 0.748 vs 0.752; syn per catalyst-check 1.80·10⁻² vs 1.87·10⁻² (z = −0.7) |
| bond lengths, high statistics (`soup_small`, chem = 0, 77 snapshots, 70 917 bonds) | 0.5429 vs 0.5439. With block errors (snapshots correlate through the slowly changing aggregates) that is −0.0010 ± 0.0023. Over the three long comparisons the GPU − reference difference is −0.0006 ± 0.0005 (z = −1.2): no significant shift, any systematic effect is below ≈ 0.2 % |
| large box L = 1024 (3.1 M beads), soup with chemistry, 20 steps | step-0 snapshot **bitwise identical** to the reference; after 20 steps the max bond (1.359395 at step 10, 1.279218 at step 20) and T_kin (2.32218 vs 2.32220) still agree with the reference to 5–7 digits; momentum 8·10⁻¹¹; 688 reactions in 7 rounds |

### Only on the GPU machine: `selftest_gpu.sh`

`selftest_gpu.sh` builds the CPU reference from `../engine/oercel.c` into `engine_gpu/build/`
(engine/ itself is never touched), runs the checks above on the GPU build, and compares them
with that reference. Sections:

| # | check |
|---|---|
| 0 | builds; **parameter parity**: every key of the *current* `engine/oercel.c` is known to oercel_gpu (detects a reference that gained parameters after this port), defaults identical |
| 1 | `--forcetest` on the GPU: pair forces vs brute force, Σ F = 0, sort, bonded forces, all architectures |
| 2 | determinism on the GPU (bitwise, with all chemistry and environment options); the parallel chemistry (cell-lock rounds) must be bitwise identical to the plain serial loop (`OERCEL_CHEM_SERIAL=1`) |
| 3 | water L = 64, 900 t.u.: ⟨T⟩ within 3 % of kT and within 4σ of the reference, momentum < 10⁻⁸, g(r) within 0.03, virial pressure within 1 % |
| 4 | lipid soup without chemistry: bond-length distribution, ⟨T⟩, aggregation |
| 5 | chemistry: `soup_small` (2 seeds per engine) and the low-noise `tests/chemstat.sh` (rates per catalyst-check, mutation fraction) |
| 6 | restart identity; SIGTERM-interrupted run + restarts into the same directory = uninterrupted run |
| 7 | checkpoints GPU → CPU engine and CPU → GPU; the first 5 steps of the CPU continuation of a `ckpt_to_cpu.py`-converted GPU checkpoint must match the GPU's own continuation (an unconverted file gives a `WARN` line, not counted, while engine/oercel.c does not carry forces at restart) |
| 8 | teamA membranes L = 64, 2 seeds × 2 engines: `tools/analyze.py` vesicle counts in the same range, `tools/render.py` works |
| 9 | food supply (`engine/tests/feedcheck.py`: rate, region, cap), stirring profile (u0 vs the reference's 0.266), temperature cycle |
| 10 | pi and y lipids (with `syn_nN`) vs the memB CPU engine (`ref/oercel_memB.c`) |
| 11 | ms/step at L = 128, 256, 512, 1024 (`--big`: also 2048 and 4096), per-phase split, and the CPU reference with all cores |

Output goes to `engine_gpu/testruns/selftest_<date>/` (`summary.txt`, `selftest.log`). The exit
code is the number of failed checks. Options:
- `--quick`: shorter runs;
- `--only "3 8"`: only these sections;
- `--big`: larger benchmark sizes;
- `--emu`: test the emulation build. This is how the script itself was tested here.

**Troubleshooting on the GPU.**
- If a check fails on the GPU but passes with `--emu`:
  - rerun the failing section with `OERCEL_SYNC=1` to locate the kernel;
  - compare `./oercel_gpu --forcetest 23.7` with `./oercel_emu --forcetest 23.7`.
- "no CUDA device": see `setup_wsl.sh` section 1.

## Performance (estimate — not measured, there is no GPU here)

- **Per step:** about 15 kernel launches, one 40-byte device→host read, and device-resident
  chemistry.
- **Pair kernel:** ≈ 27 candidates and ≈ 9.4 interacting pairs per bead, ≈ 1000 instructions per
  bead.
- **Memory traffic:** ≈ 250 bytes per bead per step.
- **Estimate for the Quadro RTX 8000** (72 SMs, 16 TFLOP/s FP32, 672 GB/s), at 30–50 % of peak:
  - ≈ 1–3 ms/step at L = 1024 (3.1 M beads);
  - ≈ 4–12 ms/step at L = 2048 (12.6 M);
  - ≈ 15–50 ms/step at L = 4096 (50 M).
- **Small boxes** (L = 128: ≈ 0.2–0.5 ms/step) are bound by launch latency and the per-step
  synchronisation. WSL2 adds latency to every CUDA call.
- **Chemistry** costs roughly rounds × (3 launches + one GPU thread running a whole reaction,
  ≈ 0.3–1 ms) per check.
- **For comparison:** the CPU reference does 2.2 ms/step at L = 128 on 2 Xeon cores (scalar code
  on CPUs without AVX-512 is 1.6–1.8× slower).
- The selftest prints the real numbers, including the CPU reference with all cores of the
  machine.
- The emulation build is 3–5× slower than the CPU reference, because it does twice the pair work
  and has no SIMD. It is for testing only.

## Files

| file | purpose |
|---|---|
| `oercel_gpu.cu` | the engine (CUDA + emulation single source) |
| `Makefile` | builds |
| `setup_wsl.sh` | prerequisites on WSL2 + build |
| `selftest_gpu.sh` | GPU self-test and benchmark |
| `run_bg.sh` | start/continue a run in the background (nohup + setsid) |
| `ckpt_to_cpu.py` | re-order a GPU checkpoint for the CPU engine (see "Switching a run to the CPU engine") |
| `tests/compare.py` | statistical comparisons (water, bonds, vesicles, chem, ident) |
| `tests/chemstat.sh` | low-noise chemistry statistics (both engines) |
| `tests/run_soup_compare.sh` | the teamA L = 64 two-seed comparison |
| `tests/bigbox_smoke.sh` | large-box smoke test (step-0 snapshot vs the reference, a few steps) |
| `tests/*.ini` | copies of `water.ini`, `soup_small.ini`, `teamA_membranes.ini` (fallbacks) |
| `ref/oercel_ref.c`, `ref/oercel_memB.c` | frozen copies of the reference sources this port corresponds to (engine md5 `f760b805…`, memB md5 `88439df6…`); the memB copy is needed because `runs/` is not in git |
| `NOTES.md` | work log |

## Requests for engine/ and tools/ (none are required for oercel_gpu to work)

1. `engine/tests/snapcheck.py`: `read_ckpt` accepts only checkpoint version 2. memB version 3
   (linear → 2; pi / y / bola → 3, with an int32 `arch` after `nH`) needs a 4-byte skip. Both
   engines write v3 for non-linear lipids.
2. `engine/tests/validate.sh` hard-codes `ENG=engine/oercel`. An override such as
   `ENG=${ENG:-engine/oercel}` would let the reference validation suite run on `oercel_gpu`
   unchanged (`selftest_gpu.sh` covers the same checks in the meantime).
3. `tools/cells.py` rasterises every snapshot on an h = 0.25 grid, i.e. (4L)² pixels: 16.7 M at
   L = 1024 and 268 M at L = 4096, with an int16 lumen label grid. The analysis was only exercised
   at L ≤ 128. For the large boxes the GPU makes possible, it should be checked (memory,
   time) and probably work on sub-regions.
4. When the memB lipid architectures are merged into `engine/oercel.c`, keep the key names and
   semantics. Then oercel_gpu needs no change, and selftest section 0 confirms the parity.
5. `engine/oercel.c` (and `runs/memB_src/oercel.c`), `main()`: at restart, `sort_cells(s)` is
   assumed to be the identity, but it permutes every per-bead array except `fx, fy`. That holds
   only for a checkpoint written by the same engine with the same `nsub`. A GPU checkpoint (or a
   CPU restart with a different `nsub`) starts with forces of other beads for one step. Fix: right
   after that `sort_cells(s)`, permute the forces with the sort's `src[]` (new slot d ← old slot
   `src[d]`), e.g. `for (d) x2[d] = fx[src[d]]; swap(fx, x2);` and the same for `fy` (x2/y2 are
   free scratch after the sort). Then `ckpt_to_cpu.py` is no longer needed.

## Emulation self-test runs on the development machine

| run | sections | result |
|---|---|---|
| `selftest_gpu.sh --emu --quick --only "1 2"` | forcetests, determinism | 13 / 13 PASS |
| `selftest_gpu.sh --emu --quick --only "3 5 6 7"` (`--only "5 6 7"` rerun after a script fix) | water, chemistry, restart, checkpoints | all PASS, except a "feed total" check that was itself wrong (with a binding cap the feed equals consumption; replaced by a balance report) |
| `selftest_gpu.sh --emu --quick --only "2 4 8 9 10"` | determinism, soup bonds, vesicles + tools, feed, stirring, kT cycle, architectures | 42 PASS, 1 FAIL (the over-tight bond-mean limit, since replaced by block errors; see the high-statistics row) |
| `selftest_gpu.sh --emu --quick --only "9 10"` (final script) | feed, stirring with honest errors (u0 0.2516 ± 0.0070 vs 0.266 ± 0.009, z = −1.3), kT cycle, pi/y lipids incl. chemistry | 38 / 38 PASS |
| review: `selftest_gpu.sh --emu --quick --only "2 7"` (extended sections) | determinism + serial-oracle identity; checkpoints both ways incl. the converted GPU → CPU continuation | 16 / 16 PASS, 1 WARN (the unconverted GPU → CPU restart: T 1.1202 vs 0.9912 at the first step, engine/oercel.c issue) |
| review: `selftest_gpu.sh --emu --quick --only "1 6"` | forcetests (all L and architectures), restart identity, 2 SIGTERM interruptions | 15 / 15 PASS |

The full-length (non-`--quick`) sections were not run in emulation, because they would take hours
on the shared 4-core machine. The 60 000-step teamA comparison was done separately (table above).

## Keeping the port in sync with the reference

- If `engine/oercel.c` gains parameters or physics, port the change into `oercel_gpu.cu`.
  Section 0 of the selftest flags new parameter keys.
- Parameter parsing, `mol_build`, the hashes, `a_eff`, `kT_at` and the file IO are line-by-line
  copies of the reference.
- A kernel is a `pfor(n, KL(int i) { ... })` body. It must be race free (no two threads write the
  same bead), use only `HD` functions, and capture plain values or the `Dev` view.
- If the memB features are merged into `engine/oercel.c` with the same keys, nothing needs to
  change here.
