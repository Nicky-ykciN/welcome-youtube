# Oercel engine

2D dissipative particle dynamics (DPD) with local stochastic chemistry, written in C
(OpenMP, AVX-512 fast path). This implements SPEC sections 2–6. The Z/fallback division
machinery (SPEC §6) is **not** implemented; type id 6 (`Z`) is reserved, has a row in the
repulsion matrix and is counted in `stats.csv` (always 0).

```
make              # builds ./oercel  (gcc -O3 -march=native -fopenmp)
make test         # force unit tests (cell kernel vs O(N^2) brute force, bonded vs finite differences)
tests/validate.sh # full validation suite, ~1 min, prints PASS/FAIL per check (run from anywhere)
./oercel params.ini outdir [key=value ...]   # run; extra key=value arguments override the ini
./oercel --params                            # print every parameter with its default
```

Example parameter files in `params/`: `soup_small.ini` (L = 64 random soup), `seeded_small.ini`
(L = 64, one pre-built vesicle with Ka inside, for testing growth/division only, never for the
final claims), `water.ini` (pure water, used for validation).

## Running long simulations in chunks

`steps` is the **absolute** step number at which the run ends. The engine stops cleanly, finishing
the current step and writing `ckpt.bin`, on SIGTERM/SIGINT (so `timeout` works) or when
`walltime` seconds have elapsed. To continue, run the same command again with
`restart=outdir/ckpt.bin`:

```
timeout 540 engine/oercel engine/params/soup_small.ini runs/x walltime=520
timeout 540 engine/oercel engine/params/soup_small.ini runs/x walltime=520 restart=runs/x/ckpt.bin
...                                    # repeat until the log says "done at step <steps>"
```

A restart into the same directory first truncates `stats.csv`/`events.csv` after the checkpoint
step (it also drops a partially written last line), then appends. The interrupted-and-restarted
run is **bitwise identical** to an uninterrupted one: every output file, including the full
`stats.csv`/`events.csv`, was verified with `cmp`. Restarting into a new directory branches the
run; add `restart_reseed=1` plus a new `seed` to get a different stochastic future.

If the parameters change at a restart, the previous `params.ini` is kept as
`params_before_<step>.ini`. Lines that cannot change the trajectory (`threads`, `walltime`,
`log_every`, `restart`) are ignored in that comparison. `ckpt_keep=1` additionally keeps
`ckpt_<step>.bin` copies, e.g. to branch from just before a division.

## Parameters

Every option lives in the ini file (`key = value`, `#` comments). Unknown keys are an error,
so typos cannot pass silently. The run directory receives `params.ini` with **all**
parameters actually used: defaults filled in, the full repulsion matrix, the derived σ, and
command-line overrides listed in a comment.

| key | default | meaning |
|---|---|---|
| `L` | 64 | box side (rc units); N = round(rho*L*L) |
| `rho` | 3 | bead number density |
| `dt` | 0.03 | time step |
| `lambda` | 0.65 | Groot-Warren velocity-prediction lambda |
| `gamma` | 4.5 | DPD friction; sigma = sqrt(2*gamma*kT) is derived |
| `kT` | 1 | thermostat temperature |
| `k_bond` | 100 | harmonic bond constant, U = k/2 (r-r0)^2 |
| `r0` | 0.5 | bond rest length |
| `k_angle` | 10 | angle constant, U = k (1 - cos theta) on consecutive triplets |
| `lip_nH` | 1 | head beads per lipid |
| `lip_nT` | 3 | tail beads per lipid |
| `steps` | 10000 | run until this absolute step number |
| `snap_every` | 1000 | snapshot interval (0 = none) |
| `stats_every` | 100 | stats.csv interval (0 = none) |
| `ckpt_every` | 10000 | checkpoint interval (0 = only at the end) |
| `ckpt_keep` | 0 | 1 = also keep ckpt_<step>.bin copies |
| `log_every` | 1000 | log line interval |
| `warmup` | 1000 | fresh soup/seeded starts: repulsion above 25 is ramped in linearly over the first warmup steps (0 = off; not applied after restart) |
| `threads` | 2 | OpenMP threads |
| `nsub` | 4 | performance only: y sub-cells per unit cell (1..8); same physics, different round-off order |
| `seed` | 1 | random seed |
| `init` | soup | soup, seeded or restart |
| `restart` | (empty) | checkpoint file; if non-empty the run restarts from it |
| `restart_reseed` | 0 | 1 = on restart use this ini's seed (branch) instead of the checkpoint's |
| `walltime` | 0 | stop cleanly (with checkpoint) after this many seconds (0 = off) |
| `chem` | 1 | 1 = chemistry on |
| `n_chem` | 10 | chemistry check interval (steps); all p_* are per check |
| `r_cat` | 1.2 | catalyst reaction radius |
| `syn_tries` | 8 | new lipid: orientation = lowest overlap energy of this many random ones (1 = purely random) |
| `syn_relax` | 20 | new lipid: steepest-descent iterations moving only its own beads (step <= 0.05 each; 0 = off) |
| `p_syn_a` | 0.02 | lipid synthesis probability per check, Ka |
| `p_syn_b` | 0.06 | lipid synthesis probability per check, Kb |
| `p_rep_a` | 0.001 | catalyst replication probability per check, Ka |
| `p_rep_b` | 0.001 | catalyst replication probability per check, Kb |
| `mu` | 0.02 | mutation probability per replication (a<->b) |
| `p_ld` | 2e-4 | lipid decay probability per molecule per check |
| `p_kd` | 5e-4 | catalyst decay probability per check |
| `p_nd` | 1e-4 | nutrient decay probability per check |
| `feed` | 1 | 1 = food supply in the outside medium |
| `feed_every` | 0 | food supply interval in steps (0 = n_chem) |
| `c_N` | 0.12 | target nutrient fraction in the outside medium |
| `feed_grid` | 1.6 | coarse grid cell size for the outside flood fill |
| `feed_tmin` | 1 | a grid cell with >= feed_tmin T beads is membrane |
| `events` | 1 | 1 = write events.csv |
| `f_lip` | 0.10 | soup: fraction of beads in lipids |
| `f_Ka` | 0.005 | soup: fraction of beads that are Ka |
| `f_Kb` | 0 | soup: fraction of beads that are Kb |
| `seed_R` | 10 | seeded: vesicle bilayer mid-plane radius |
| `seed_spacing` | 0.7 | seeded: lipid spacing along each leaflet |
| `seed_cN_in` | -1 | seeded: nutrient fraction inside (-1 = c_N) |
| `seed_nKa` | 6 | seeded: number of Ka placed in the lumen |

Default repulsion matrix a_ij (key `a_X_Y`, symmetric; `a_K_X` sets Ka and Kb at once):

|    | W | H | T | N | Ka | Kb | Z |
|---|---|---|---|---|---|---|---|
| **W** | 25 | 20 | 80 | 25 | 25 | 25 | 25 |
| **H** | 20 | 25 | 50 | 25 | 30 | 30 | 25 |
| **T** | 80 | 50 | 25 | 40 | 120 | 120 | 25 |
| **N** | 25 | 25 | 40 | 25 | 25 | 25 | 25 |
| **Ka** | 25 | 30 | 120 | 25 | 25 | 25 | 25 |
| **Kb** | 25 | 30 | 120 | 25 | 25 | 25 | 25 |
| **Z** | 25 | 25 | 25 | 25 | 25 | 25 | 25 |

Notes:
- σ = sqrt(2 γ kT) is always derived (fluctuation–dissipation); it cannot be set separately.
- The lipid is a linear chain of `lip_nH` heads followed by `lip_nT` tails, at most 8 beads
  (default H–T–T–T). Bonds join consecutive beads; the angle term acts on every consecutive
  triplet.
- **Chemistry probabilities are per check** (one check every `n_chem` steps), not per unit time.
- `soup_small.ini` and the compiled defaults use the SPEC *starting* repulsion matrix. See
  "Known issues" for vesicle stability with these values.

## Physics and numerics

- **DPD pair force** for r < 1 (rc = 1, w = 1 − r):
  F = [a_ij w − γ w² (r̂·v_ij) + σ w θ_ij / √dt] r̂.
- **Pair noise**: θ_ij is uniform on [−√3, √3) (unit variance), a pure function of
  (seed, step, min(gid_i, gid_j), max(gid_i, gid_j)). The hash is the splitmix64 finaliser of
  ((min ≪ 32 | max)·φ) XOR a per-step key, so it is symmetric, thread-safe and reproducible.
  Tested: mean 0.001, variance 1.001, lag-1 correlation 0.0004 over 10⁶ pairs.
- **Bonded**: harmonic bonds ½ k_bond (r − r0)²; angle U = k_angle (1 − cos θ), θ the deviation
  from straight. All pair interactions also act between bonded beads (no exclusions).
- **Integrator**: Groot–Warren modified velocity Verlet, λ = 0.65. The stored velocity is the
  half-step one, vh = v − (dt/2) f, which fuses the second half-kick into the next step:
  x += dt·vh + dt²·f; ṽ = vh + (½ + λ) dt·f (force input); vh += dt·f.
  The full velocity v = vh + (dt/2) f is used for T_kin.
- **Kinetic temperature**: T = Σ v² / (2N − 2) in 2D (mass 1).
- **Warm-up** (fresh `soup`/`seeded` starts only, `warmup` steps, default 1000 = 30 time
  units): the part of every a_ij above 25 is ramped in linearly. The random initial soup
  otherwise contains overlapping beads with a = 80/120 repulsions, which stretched bonds to
  1.70 in the first 10 steps (measured). With the ramp, the initial maximum is 1.0–1.2.
  Physics after the warm-up is unaffected; the ramp state is checkpointed.

## Chemistry (SPEC §3)

Order inside step n (n = step being computed): positions/velocities are advanced. If
n % n_chem == 0, the reactions run on this new configuration, then decay. If
n % feed_every == 0, the food supply runs. Then come the cell sort and the forces. Events are
labelled with step n, so `snap_n` already contains their effect. Neighbour searches use the
cell index of the previous sort; since every bead moved < 0.5 since then (checked each step,
with a fallback re-sort if ever violated), the search window is simply enlarged by 0.5.

1. **Catalysts** (Ka and Kb) are visited in a random order (shuffled with the serial
   xoshiro256** RNG, which is checkpointed). For each K, the N beads within `r_cat` are
   collected and sorted by distance (ties broken by gid).
   - **Synthesis**: if ≥ mlen N are present, with probability p_syn(variant), the mlen nearest
     N become a lipid (heads first). They are re-placed as a straight chain with spacing r0
     centred on their centroid and all given their mean ṽ and vh (momentum conserving), and
     the bonds are created at rest length. Two documented refinements:
     - Orientation: the lowest conservative overlap energy among `syn_tries` random
       orientations (1 = purely random as in SPEC).
     - `syn_relax` steepest-descent iterations moving only the new chain's beads in the frozen
       field of their neighbours (each bead moves ≤ 0.05 per iteration).

     Both reduce post-synthesis bond stretching (see "Known issues").
   - **Replication** (independent draw, using the remaining N): if ≥ 2 N remain, with
     probability p_rep(variant), the nearest becomes K of the same variant (or of the other
     variant with probability mu, logged as `mut`) and the next nearest becomes W.
2. **Decay**: every lipid with p_ld becomes mlen × W (bonds removed); every K with p_kd and
   every N with p_nd becomes W. These decisions use a counter-based hash of
   (seed, step, gid, kind), so they are parallel and order independent.
3. **Food supply**: on a coarse grid of side ≈ `feed_grid`, cells holding ≥ `feed_tmin`
   T beads are membrane. The largest 4-connected periodic region of the remaining cells is
   the outside medium. Random W in it are converted to N until N/(all beads there) ≥ c_N.
   Nutrients reach a lumen only by permeating the membrane (permeability set by a_N_T).

## Output files (SPEC §5)

- `snap_<step:010d>.bin`: exactly the SPEC layout (little-endian header, float32 x and y,
  uint8 type and int32 bonds, all indexed by **permanent bead id** = gid, bonds with i < j).
  A bead's id never changes, so ids track beads across snapshots and events. Snapshots are
  written to a temporary file and renamed, so a reader never sees a partial file. Bonds are
  listed in order of the first bead's id.
- `stats.csv`: `step,time,T_kin,nW,nH,nT,nN,nKa,nKb,nZ,n_lipids,max_bond`, with
  - `T_kin`: instantaneous at that step;
  - `max_bond`: the largest bond length over **all steps since the previous row**, not just
    this one, so transients cannot hide between rows;
  - `time = t_anchor + (step − step_anchor)·dt`, which equals step·dt unless dt was changed
    at a restart.
- `events.csv`: `step,kind,i,x,y,variant`

  | kind | i | x, y | variant |
  |------|---|------|---------|
  | `syn` | gid of the catalyst | catalyst position | `a`/`b` of the catalyst |
  | `rep` | gid of the **new** catalyst bead | parent catalyst position | `a`/`b` (= parent's) |
  | `mut` | gid of the new catalyst bead (replication that switched variant) | parent position | new variant |
  | `dlip` | gid of the lipid's first head | head position | `-` |
  | `dK` | gid of the catalyst | its position | its variant |
  | `dN` | gid of the nutrient | its position | `-` |
  | `feed` | **number** of W→N conversions at this step (aggregated) | `nan,nan` | `-` |

  `rep` does not include `mut`: the total replications are rep + mut. Variant encoding:
  `a` = Ka, `b` = Kb, `-` = not applicable. (Checked: `tools/ocio.read_events` parses this.)
- `params.ini` (see above), `log.txt` (the console log is also appended here).
- `ckpt.bin`: the latest checkpoint, written atomically (temporary file + fsync + rename).
  Format version 1, little-endian:

  ```
  char[4]  "OCKP"
  int32    version = 1
  int32    N, mlen (beads per lipid), nH (heads per lipid)
  int64    step
  float64  time, L
  uint64   seed            (the pair-noise / hash seed in use)
  uint64   rng[4]          (xoshiro256** state of the serial chemistry RNG)
  float64  maxbond         (running max since the last stats row)
  int64    warm_end        (step at which the warm-up ramp ends; 0 = none)
  float64  t_anchor; int64 step_anchor; float64 dt_anchor   (time bookkeeping)
  --- per-bead arrays, N entries each, in the engine's internal (cell-sorted) slot order ---
  uint32   gid[N]          (permanent bead id of each slot)
  uint8    type[N]
  int8     mpos[N]         (position in its lipid, 0 = first head; -1 = not a lipid)
  int32    nxt[N]          (slot of the next bead in its lipid chain; -1 = none)
  float64  x[N], y[N]
  float64  vx[N], vy[N]    (half-step velocity vh; full v = vh + dt/2 f)
  float64  fx[N], fy[N]    (forces of the stored configuration)
  char[4]  "END!"
  ```

  The slot order is stored on purpose: restoring it exactly makes the continuation bitwise
  identical. On load, the engine verifies that the gids form a permutation and that the lipid
  links are consistent.

## Determinism

For a given binary and CPU, a run is a deterministic function of its parameters, **for any
number of threads**. The force summation order is fixed by the strip decomposition (below),
the sort is a stable counting sort, chemistry is serial or uses counter-based hashes, and
all list merges are in slot order. Verified: a restart from 3 threads to 1 thread gives
bitwise identical snapshots, stats, events and checkpoint. `nsub` changes the order of
floating-point summation and therefore the bits, but not the physics.

## Performance design

- All per-bead state is kept in cell order. A stable parallel counting sort, in gather form
  (inverse permutation, one array at a time), runs every step. Cells are 1 wide in x and are
  split into `nsub` (default 4) sub-cells in y. Array base addresses are staggered to avoid
  4K-aliasing.
- Pair forces use a half-shell, race free without per-thread buffers. Columns are grouped into
  an even number of strips; even strips run concurrently, then odd ones. A strip writes only
  to its own columns and the first column of the next strip. Each bead i looks at two
  contiguous slot ranges selected by its own y window: its own column upward to y_i + 1, and
  the next column over y_i ± 1.
- AVX-512 kernel (automatic when the CPU supports AVX-512 F/DQ/BW/VL; otherwise a scalar
  version is compiled, also tested). Eight candidates per vector use masked contiguous loads
  and stores (no gathers or scatters). The 8×8 a_ij table is one register (`permutexvar`),
  the pair hash is vectorised (`vpmullq`), and 1/r comes from `rsqrt14` plus two Newton steps
  (full double precision). Checked against brute force to 3·10⁻¹³ absolute.
- Bonded forces walk lipid chains through the per-slot `nxt` links (no gid→slot lookups, no
  cross-core traffic), in parallel; each bead belongs to one chain, so there are no races.
- Chemistry costs ≈ 2–3 % of a step: parallel scans, contiguous-range neighbour searches.

Measured ms/step on the final binary, soup with chemistry (`soup_small.ini`), minimum of
3 interleaved repetitions of 800 steps. Machine: 4-core Xeon VM (2.1 GHz nominal, ~2.65 GHz
effective), **shared with another agent** (load ≈ 1.4 during the measurement):

| L (N beads) | 1 thread | 2 threads | 4 threads |
|---|---|---|---|
| 64 (12 288) | 1.00 | 0.64 | 0.37 |
| 100 (30 000) | 2.08 | 1.16 | 0.86 |
| 128 (49 152) | 3.43 | 2.01 | 1.18 |
| 160 (76 800) | 5.69 | 3.19 | 2.14 |

Session-to-session variation on this host is up to ~25%. An earlier session (previous binary,
same kernel) gave 0.81/0.46/0.32 ms at L = 64 and 4.21/2.30/1.40 at L = 128. With 4 threads,
any CPU use by another process stalls every barrier: single samples of 13 ms/step at L = 128
were observed while the other agent was busy, so **use 2 threads** when sharing the machine.

At L = 128 with 2 threads, ≈ 2 ms/step means ≈ 1.8·10⁶ steps or ≈ 54 000 time units per hour
(dt = 0.03). Against the very first version of this engine, measured interleaved under
identical conditions (L = 128 soup): 1 thread 6.0 → 3.95 ms/step (1.5×), 2 threads
3.7 → 1.9–2.3 ms/step (1.6–2.0×); the pair kernel alone is 1.8–2× faster.

## Validation (tests/validate.sh, final binary: all 12 checks PASS)

| check | result |
|---|---|
| cell/strip kernel vs O(N²) brute force (L = 9, 12.5, 23.7; nsub = 1, 4) | max abs. difference ≤ 3·10⁻¹³ (forces up to ~250) |
| bonded forces vs finite differences | relative error ~10⁻⁹ |
| chain/cell integrity after repeated sorts | 0 errors |
| water L = 64, dt = 0.03, 900 t.u. | ⟨T⟩ = 0.9958 ± 0.0003 (−0.42 %), halves 0.9963 / 0.9952 |
| water L = 64, dt = 0.04, 900 t.u. | ⟨T⟩ = 0.9928 ± 0.0004 (−0.72 %), halves 0.9928 / 0.9927 |
| total momentum (12 288 beads) | ≤ 3·10⁻¹² over the whole run |
| water g(r) | g(0.05) = 0.02, first peak 1.08 at r = 0.85, shallow minimum 0.955 at 1.15, → 1 (soft DPD fluid) |
| restart at step 300 (3 threads → 1 thread), all reactions active | snapshots, stats, 1341 events, final checkpoint bitwise identical |
| run killed twice by `timeout`, restarted into the same directory | every output file bitwise identical to the uninterrupted run |
| soup L = 64, no chemistry, 60 000 steps | T-neighbour fraction 0.20 → 0.83, max bond 1.087, ⟨T⟩ = 0.9928 |

Longer runs (`runs/val_*`, analysed with `tests/snapcheck.py`; quick-look PNGs from
`tests/quicklook.py` are in the run directories):
- `val_soup64_nochem`, 300 000 steps = 9000 t.u., 1 thread: micelles by t = 150, coarsening
  into long bilayer strips by t = 9000. Largest tail cluster 564 of 921 T beads, T-neighbour
  fraction 0.83, **max bond over all 300 000 steps 1.136**, ⟨T⟩ = 0.9925. No vesicle closed.
- `val_soup64` (`soup_small.ini`, chemistry on), 300 000 steps, 2 threads, 0.52 ms/step:
  aggregation (T-neighbour fraction 0.20 → 0.70 by t = 150, ~0.77 later), max bond 1.343,
  ⟨T⟩ = 0.9935. With these starting rates the catalysts slowly die out (Ka 61 → 1 by t = 9000):
  near consumers the local nutrient level is below the bulk c_N, so replication is just below
  decay.

## Known issues and honest caveats

1. **Vesicles are not stable with the SPEC starting parameters.** The seeded R = 10 vesicle
   (H–T–T–T, k_angle = 10, a_W_H = 20) opens a pore after 180–780 t.u. in every run tried
   (5 runs, 4 seeds), then falls apart into bilayer strips; the catalysts escape
   (`runs/val_seeded64`, `runs/scan_ves`). Exploratory scan (chemistry off, L = 48, closure judged on the feed grid
   with `tests/vesclosed.py`, 60 000 steps, 3 seeds each):

   | parameters | still closed at the end |
   |---|---|
   | SPEC start | 0/3 |
   | k_angle = 30 | 0/3 |
   | k_angle = 30, a_W_H = 30 | 2/3 |
   | k_angle = 30, a_W_H = 35 | 1/3 (transient pores reseal) |

   Single runs that still opened: k_angle = 50, R = 15 and seed_spacing = 0.6 (all at step 6000,
   like the baseline), and H2T4, H1T5 (step 14 000) and H2T4 with k_angle = 30 (step 24 000). The membrane
   parameters therefore still need real tuning before cells can emerge. The engine supports
   all the relevant knobs (`a_*`, `k_angle`, `k_bond`, `r0`, `lip_nH`/`lip_nT`).
   `seeded_small.ini` still uses the SPEC values.
2. **Kinetic temperature with many bonded beads** is slightly low, an integrator effect of
   the stiff bonds (ω·dt ≈ 0.42 at dt = 0.03). Without chemistry, ⟨T⟩ is 0.991 at 10 % lipid
   beads and 0.982 at 60 % (dt = 0.03); 0.996 and 0.990 at dt = 0.02. Within ±3 % for all
   tested compositions, but prefer dt = 0.03 over 0.04 once membranes dominate.
3. **Bond transients after synthesis.** The only long bonds in steady state belong to lipids
   synthesised a few steps earlier, almost always the middle T–T bond, because the catalyst
   bead sits close to the middle of its new product (K–T repulsion 120). In a deliberate
   stress test (~2000 syntheses in 40 000 steps, about 10× a realistic rate), the maximum was
   1.40 with purely random orientation and 1.33 with syn_tries = 8 and syn_relax = 20. More
   relaxation (60 iterations, 16 tries) did not lower it further. This is below the SPEC
   limit of 1.5, but the margin is smaller than for pure physics (≤ 1.14).
4. The fast path needs AVX-512 (this machine has it). Elsewhere the scalar kernel is used;
   its pair kernel is ~1.6–1.8× slower, and it was tested only via `-DOERCEL_SCALAR` (forcetest PASS).
5. `init = seeded` places solvent at uniform density outside an excluded annulus of
   ±(r0·(mlen − 1) + 0.5) around the bilayer mid-plane. Leaflets get lipids every
   `seed_spacing` along radii R ± 1. This is an untuned construction (see 1).
