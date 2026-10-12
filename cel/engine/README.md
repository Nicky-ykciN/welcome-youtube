# Oercel engine

2D dissipative particle dynamics (DPD) with local stochastic chemistry, written in C
(OpenMP, AVX-512 fast path). This implements SPEC sections 2–5 under the **emergence rule**
(SPEC §0): the engine contains only laws of nature and structure-blind environmental physics,
and its only start state is a random, well-mixed soup (or a checkpoint of one). Nothing is
placed, and no rule knows about cells, membranes, compartments, inside/outside or size.
Type id 6 (`Z`) is unused (SPEC §6: no division machinery). It keeps its row in the
repulsion matrix and its `nZ` column in `stats.csv`, which is always 0.

```
make              # builds ./oercel  (gcc -O3 -march=native -fopenmp)
make test         # force unit tests (kernel vs O(N^2) brute force incl. stirring + kT(t), bonded vs finite differences,
                  #   tests/molforcetest: bonded forces of every lipid template vs finite differences)
tests/validate.sh # full validation suite, ~90 s, prints PASS/FAIL per check (run from anywhere)
./oercel params.ini outdir [key=value ...]   # run; extra key=value arguments override the ini
./oercel --params                            # print every parameter with its default
```

Example parameter files in `params/`:
- `soup_small.ini`: L = 64 random soup with chemistry and a uniform food supply. Commented
  lines show the vent, stirring and temperature-cycle options.
- `water.ini`: pure water, used for validation.
- `membranes.ini`: **the membrane physics** (tied double-tailed lipid + two-phase nutrient).
  A random soup at L = 100 forms 10-17 closed bilayer vesicles with catalysts inside within
  10-15k steps. See "Lipid templates and the membrane physics". `runs/membranes_final/ckpt.bin`
  is this file run as-is to step 100 000 (vesicle-rich starting state for the next stages).

## What the emergence rule removed (and how the engine guards it)

| removed | why (SPEC §0) | what happens now |
|---|---|---|
| `init = seeded` (a pre-built vesicle with catalysts inside), keys `seed_R`, `seed_spacing`, `seed_cN_in`, `seed_nKa` | placed structure | `init` is `soup` or `restart`; the old values give an explicit error |
| `feed = 1`: the flood fill of the "outside medium" on a coarse grid, keys `feed_every`, `feed_grid`, `feed_tmin` | the rule knew where membranes were | replaced by the structure-blind `uniform` and `vent` supplies (below); the old keys give an explicit error |
| checkpoint format 1 | such a file may come from a seeded or flood-fed run | the engine refuses version 1 checkpoints; version 2 files can only come from a soup (see "Output files") |

The runs made with the removed features were deleted: `runs/val_seeded64` and `runs/scan_ves`
(seeded), and `runs/val_soup64` (flood-fed; regenerated with this engine). In the toolkit's
scratch area, the seeded runs `/tmp/oercel_scratch/runs/{seeded48,seedgrow,partial}` and
the flood-fed runs `{soup64,soup128,val_chunk_D,val_restart_B}` were deleted, together with
the scratch images rendered from seeded runs. `params/seeded_small.ini` and
`tests/vesclosed.py` (a closure check for the placed vesicle on the old feed grid) were also
removed. `runs/val_soup64_nochem` (chem = 0, so no food supply ever ran) was kept. This
engine reproduces its bead data exactly (see "Determinism"), but its `ckpt.bin` is version 1
and cannot be restarted.

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
run is **bitwise identical** to an uninterrupted one. Every output file, including the full
`stats.csv`/`events.csv`, was checked with `cmp`, with the food supply, stirring and the
temperature cycle all active. Restarting into a new directory branches the run; add
`restart_reseed=1` plus a new `seed` to get a different stochastic future. Starting a new
experiment from the checkpoint of an earlier soup run is allowed (SPEC §4); the log records
the seed of the random soup the run descends from.

If the parameters change at a restart, the previous `params.ini` is kept as
`params_before_<step>.ini`. Only `key = value` matters in that comparison: help comments,
and lines that cannot change the trajectory (`threads`, `walltime`, `log_every`, `restart`),
are ignored. `ckpt_keep=1` additionally keeps `ckpt_<step>.bin` copies, e.g. to branch from
just before an interesting event.

## Parameters

Every option lives in the ini file (`key = value`, `#` comments). Unknown keys are an error,
so typos cannot pass silently. The run directory receives `params.ini` with **all**
parameters actually used: defaults filled in, vent coordinates resolved, the full repulsion
matrix, the derived σ, and command-line overrides listed in a comment.

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
| `lip_nH` | 1 | head beads per lipid (linear) |
| `lip_nT` | 3 | tail beads per lipid (linear) or per tail (pi, y, bola) |
| `lip_arch` | linear | lipid molecule template: `linear` (lip_nH heads then lip_nT tails), `pi` (2 bonded heads, each carrying a tail of lip_nT beads), `y` (1 head carrying two tails), `bola` (head pair, two tails, one head at the other end) |
| `r0_head` | 0.5 | pi/bola: rest length of the head-head bond and of the tie bonds |
| `k_head` | 0 | pi/y/bola: junction angle term U = k_head (cos θ − cos_head)² at the branch beads (0 = free) |
| `cos_head` | 0 | pi/y/bola: preferred cos of the junction deviation angle |
| `lip_tie` | 0 | pi/y/bola: number of tie bonds (ladder rungs) between bead m of tail a and bead m of tail b, m = 1..lip_tie |
| `syn_nN` | 0 | lipid synthesis consumes syn_nN N; the remaining beads of the new lipid are the nearest W of the catalyst (0 = all beads from N) |
| `steps` | 10000 | run until this absolute step number |
| `snap_every` | 1000 | snapshot interval (0 = none) |
| `stats_every` | 100 | stats.csv interval (0 = none) |
| `ckpt_every` | 10000 | checkpoint interval (0 = only at the end) |
| `ckpt_keep` | 0 | 1 = also keep ckpt_<step>.bin copies |
| `log_every` | 1000 | log line interval |
| `warmup` | 1000 | fresh soup starts: repulsion above 25 is ramped in linearly over the first warmup steps (0 = off; not applied after restart) |
| `threads` | 2 | OpenMP threads |
| `nsub` | 4 | performance only: y sub-cells per unit cell (1..8); same physics, different round-off order |
| `seed` | 1 | random seed |
| `init` | soup | soup (random well-mixed start) or restart (continue a checkpoint of a soup run) |
| `restart` | (empty) | checkpoint file; if non-empty the run restarts from it |
| `restart_reseed` | 0 | 1 = on restart use this ini's seed (branch) instead of the checkpoint's |
| `walltime` | 0 | stop cleanly (with checkpoint) after this many seconds (0 = off) |
| `chem` | 1 | 1 = chemistry on (reactions, decay and food supply) |
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
| `feed` | uniform | food supply W -> N, structure blind: none, uniform (every W anywhere) or vent (every W inside the fixed vent region) |
| `p_feed` | 1e-3 | probability per chemistry check that an eligible W becomes N |
| `feed_cap` | 0.12 | global cap on the nutrient fraction nN/N_beads: conversions that would exceed it are dropped at random (0 = no cap) |
| `vent_shape` | disk | feed = vent: disk (radius vent_r around (vent_x, vent_y)), vstrip (abs(x - vent_x) < vent_w/2, all y) or hstrip (abs(y - vent_y) < vent_w/2, all x) |
| `vent_x` | -1 | vent centre x (-1 = L/2); fixed coordinates |
| `vent_y` | -1 | vent centre y (-1 = L/2); fixed coordinates |
| `vent_r` | 5 | vent disk radius |
| `vent_w` | 4 | vent strip width |
| `events` | 1 | 1 = write events.csv |
| `stir_A` | 0 | stirring: Kolmogorov body force f_x = stir_A sin(2 pi stir_n y / L) on every bead (net force removed; 0 = off) |
| `stir_n` | 1 | stirring: number of sine periods across the box |
| `kT_amp` | 0 | temperature cycle: kT(t) = kT + kT_amp sin(2 pi t / kT_period), applied through sigma (0 = off) |
| `kT_period` | 1000 | temperature cycle period (time units) |
| `f_lip` | 0.10 | soup: fraction of beads in lipids |
| `f_Ka` | 0.005 | soup: fraction of beads that are Ka |
| `f_Kb` | 0 | soup: fraction of beads that are Kb |
| `c_N` | 0.12 | soup: initial nutrient fraction |

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
  With the temperature cycle, σ(t) = sqrt(2 γ kT(t)).
- The lipid follows a molecule template, at most 12 beads. The default `lip_arch = linear` is
  the chain of `lip_nH` heads followed by `lip_nT` tails (default H–T–T–T): bonds join
  consecutive beads and the angle term acts on every consecutive triplet. The branched
  templates are described in "Lipid templates and the membrane physics".
- **Chemistry probabilities are per check** (one check every `n_chem` steps), not per unit time.
- `soup_small.ini` and the compiled defaults use the SPEC *starting* repulsion matrix and
  untuned starting rates (see "Known issues").

## Physics and numerics

- **DPD pair force** for r < 1 (rc = 1, w = 1 − r):
  F = [a_ij w − γ w² (r̂·v_ij) + σ(t) w θ_ij / √dt] r̂.
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
- **Kinetic temperature**: T = Σ v² / (2N − 2) in 2D (mass 1). This is the lab-frame value; with
  stirring it includes the kinetic energy of the mean flow (see below).
- **Warm-up** (fresh soup starts only, `warmup` steps, default 1000 = 30 time units): the part
  of every a_ij above 25 is ramped in linearly. This is a global, time-dependent law that
  treats every pair of types the same way, not a placement. Without it the random initial
  soup contains overlapping beads with a = 80/120 repulsions, which stretched bonds to 1.70
  in the first 10 steps (measured). With the ramp, the initial maximum is 1.0–1.2. Physics
  after the warm-up is unaffected; the ramp state is checkpointed.

## Lipid templates and the membrane physics (`params/membranes.ini`)

A lipid is a fixed molecule template: bead types by position (heads first), a list of bonds
(with their rest lengths) and a list of angle terms. It is a law of nature of this world (one
kind of molecule), the same for every lipid, whether it comes from the soup or from synthesis.
The beads of one molecule stay linked through `nxt` in template order, so sorting, decay and
checkpoints treat every template the same way.

| `lip_arch` | beads | bonds | angle terms |
|---|---|---|---|
| `linear` | lip_nH heads, then lip_nT tails | consecutive beads, r0 | k_angle (1 − cos θ) on consecutive triplets |
| `pi` | H1, H2, tail a (lip_nT beads on H1), tail b (on H2) | H1–H2 at r0_head; along each tail at r0; lip_tie rungs a_m–b_m at r0_head | k_angle along each tail; k_head at the junctions |
| `y` | H, tail a, tail b (both on H) | along each tail at r0; rungs at 1.2 r0 | k_angle along each tail; k_head between the two first tail beads |
| `bola` | H1, H2, H3, two tails from H1 and H2 that join at H3 | as pi, plus both tails bonded to H3; rungs shorten towards H3 | as pi |

`tests/molforcetest` checks the bonded forces of ten templates against finite differences of an
independently written energy, and the template geometry (all bonds at rest length).

**The membrane physics** (`params/membranes.ini`; tuned by team memB on top of team memA's
two-phase nutrient, compared head-to-head in `runs/judge_src/NOTES.md`):
- Lipid: `lip_arch = pi`, `lip_nT = 1`, `lip_tie = 1`, `r0_head = 0.7`, i.e. a small H2T2
  rectangle with 4 bonds (H1–H2 0.7, H–T 0.5, T–T tie 0.7) and **no angle terms** (k_angle has
  no effect on it). Tied tails cannot splay, so bilayers form no Y/T junctions.
- `k_bond = 300`: new lipids are synthesised inside the nutrient/catalyst lumen, which repels
  tails; with k_bond 100 their bonds stretched to 1.5–2.1. The stiffer bonds cost about 1.5 % in
  T_kin (0.985).
- Nutrient N does not mix with plain water (`a_W_N = 45`), so the soup demixes into N-rich
  droplets (an aqueous two-phase system). Heads slightly prefer N (`a_H_N = 22`); tails repel
  water and N strongly (`a_W_T = 200`, `a_T_N = 120`, `a_T_K = 200`). Lipids wrap each droplet in
  a bilayer, heads facing the N lumen and the water. Catalysts are as water-shy as their
  substrate (`a_W_K = 45`) and sit in the droplets before they close.
- Measured (chem = 0, L = 100, 100k steps, `tools/cells.py` detector, mean over 50k–100k):
  10–13 closed vesicles (seeds 1, 2, 3, 7, 8: 13.4, 13.6, 11.7, 9.7, 11.3; peak 15–17); the
  first ≥ 3 after 10–15k steps; 95–100 % contain catalysts (median 10–13). With memA's linear
  H–T–T–T physics, the same measure gave 4.3 and 6.6 (seeds 7, 8). Neither ingredient alone
  does it: the linear lipid with these tail repulsions gave 6–8 cells, mostly networked; the pi
  lipid with memA's repulsions gave none.
- Catalysts never crossed an intact bilayer (900 τ windows with snapshots every 100 steps). N
  permeates slowly in both directions.
- Limits: the lumen is the N phase, so synthesis consumes it. With `p_syn_a` = 2·10⁻³ all
  vesicles were gone within 10k steps; with 2·10⁻⁴ about half within 30k. Loose bilayer
  ribbons (excess lipid) coexist with the vesicles. Without chemistry the vesicles coarsen
  slowly (≈ 11 → 8.5 between 100k and 200k steps).

## Environment: uniform physics for every bead (SPEC §0, §6)

Both options are off by default. Neither one looks at bead types or structures.

**Gentle stirring (Kolmogorov flow), `stir_A`, `stir_n`.** Every bead gets the body force
f_x = A sin(2π n y / L), f_y = 0. For a finite sample, Σ_i f_x,i fluctuates around zero
(≈ A·sqrt(N/2)). This net force is subtracted equally from every bead, so total momentum is
conserved exactly (to ~1e-12, checked). The sum runs over 64 fixed blocks, which keeps
results thread-count independent. The DPD fluid responds with the steady Navier–Stokes
profile ⟨v_x⟩(y) = u0 sin(2π n y / L), with u0 = A / (ν k²), k = 2π n / L.
- Measured in water, L = 48, A = 0.0015 (tests/validate.sh §7): u0 = 0.266 ± 0.005, a pure
  sine (profile χ² = 9.0 for 14 dof, cos part 0.002 ± 0.005, ⟨v_y⟩ = 0). This gives a
  **kinematic viscosity ν = 0.33**.
- The flow develops on a time scale 1/(ν k²): ≈ 180 t.u. at L = 48, ≈ 310 at L = 64, ≈ 1300 at L = 128.
- The maximum shear rate is u0·k.
- Typical gentle values:

  | box | A | u0 | max shear rate |
  |---|---|---|---|
  | L = 64 | 2e-4 | ≈ 0.06 | ≈ 0.006 |
  | L = 128 | 1e-4 | ≈ 0.13 | ≈ 0.006 |

- `T_kin` in `stats.csv` is the lab-frame value, ≈ kT + u0²/4. In water it was
  T_kin − u0²/4 = 0.9963, the same as without stirring. In a stirred soup (L = 64,
  A = 0.002, a deliberately strong flow with u0 = 0.54), the lab T_kin was 1.076 while the
  thermal (peculiar) temperature, after subtracting the fitted flow, was 1.004.
- The force uses a branch-free, vectorised sin(2πu) (Taylor series after range reduction;
  agrees with libm to < 3e-15). Cost: +0.027 ms/step at L = 128 with 2 threads (≈ 1.4 %),
  only when A ≠ 0.

**Slow temperature cycle, `kT_amp`, `kT_period`.** kT(t) = kT + kT_amp·sin(2π t / kT_period)
enters only through the noise amplitude σ(t) = sqrt(2 γ kT(t)). The friction γ and the
conservative a_ij stay fixed, so heating makes thermal agitation stronger relative to the
fixed interactions, like a day/night or wet/dry cycle. t is the simulation time (checkpointed).
Measured in water, kT(t) = 1 + 0.2 sin(2π t / 30): the kinetic temperature follows as
T_kin = 0.9953 + 0.1961 sin(2π t/30 − 0.102). That is 98 % of the amplitude, with a lag of
0.49 t.u. (the thermostat response time). The log line shows the target kT(t) next to the
measured T. |kT_amp| < kT is enforced.

## Chemistry (SPEC §3)

Order inside step n (n = step being computed): positions/velocities are advanced. If
n % n_chem == 0, one chemistry check runs on this new configuration: reactions, then decay,
then the food supply. Then come the cell sort and the forces. Events are labelled with step
n, so `snap_n` already contains their effect. Neighbour searches use the cell index of the
previous sort. Every bead moved < 0.5 since then (checked each step, with a fallback re-sort
if ever violated), so the search window is simply enlarged by 0.5.

1. **Catalysts** (Ka and Kb) are visited in a random order (shuffled with the serial
   xoshiro256** RNG, which is checkpointed). For each K, the N beads within `r_cat` are
   collected and sorted by distance (ties broken by gid).
   - **Synthesis**: if ≥ mlen N are present, with probability p_syn(variant), the mlen nearest
     N become a lipid (heads first). With `syn_nN` > 0, only the syn_nN nearest N are used and
     the rest of the molecule comes from the nearest W. The beads are re-placed in the template
     geometry (a straight chain with spacing r0 for `linear`), centred on their centroid. All
     of them get their mean ṽ and vh (momentum conserving), and every template bond is created
     at rest length. Two documented refinements, both local (they see
     only the immediate neighbourhood of the new molecule):
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
3. **Food supply** (SPEC §3.4): a local, structure-blind law. Its only inputs are a bead's
   own type and position and, for the cap, the global N count. Each eligible W becomes N with
   probability `p_feed` per check, decided by a counter-based hash of (seed, step, gid), so
   it is parallel and independent of order and thread count.
   - `feed = uniform`: every W anywhere is eligible (like light or geochemistry producing
     nutrients everywhere, inside and outside any structure alike).
   - `feed = vent`: only W inside a fixed region of the box is eligible: a disk (`vent_r`
     around `vent_x`, `vent_y`), or a strip of width `vent_w` at fixed x (`vstrip`) or fixed y
     (`hstrip`), periodic. Nutrients then diffuse outward and decay (`p_nd`), which forms a
     gradient. Example: L = 64 soup, disk r = 6, p_feed = 0.02, p_nd = 1e-3. The N fraction
     falls from 0.73 at the centre to 0.33 at r = 6–9, 0.13 at r = 12–15 and 0.02 at
     r = 27–30 (mean of t = 1050–1800).
   - `feed_cap` (both modes): if the conversions of one check would raise the global N
     count above floor(feed_cap · N_beads), a uniformly random subset of them is kept (serial
     RNG). The steady state without a cap is set by p_feed versus p_nd and consumption.
   - `feed = none`: no supply (closed system).
   - The supply runs only with `chem = 1`. All conversions of a check are logged as one
     `feed` event (i = count).

## Output files (SPEC §5)

- `snap_<step:010d>.bin`: exactly the SPEC layout (little-endian header, float32 x and y,
  uint8 type and int32 bonds, all indexed by **permanent bead id** = gid, bonds with i < j).
  A bead's id never changes, so ids track beads across snapshots and events. Snapshots are
  written to a temporary file and renamed, so a reader never sees a partial file. Bonds are
  listed in order of the first bead's id (for branched templates: of the molecule's template
  bead that comes first in the bond, then in template order). Every template bond is listed.
- `stats.csv`: `step,time,T_kin,nW,nH,nT,nN,nKa,nKb,nZ,n_lipids,max_bond`, with
  - `T_kin`: instantaneous at that step (lab frame);
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
  | `feed` | **number** of W→N conversions at this step (aggregated, uniform or vent) | `nan,nan` | `-` |

  `rep` does not include `mut`: the total replications are rep + mut. Variant encoding:
  `a` = Ka, `b` = Kb, `-` = not applicable. (Checked: `tools/ocio.read_events` parses this.)
- `params.ini` (see above), `log.txt` (the console log is also appended here).
- `ckpt.bin`: the latest checkpoint, written atomically (temporary file + fsync + rename).
  Format **version 2**, little-endian:

  ```
  char[4]  "OCKP"
  int32    version = 2
  int32    N, mlen (beads per lipid), nH (heads per lipid)
  int64    step
  float64  time, L
  uint64   seed            (the pair-noise / hash seed in use)
  uint64   rng[4]          (xoshiro256** state of the serial chemistry RNG)
  float64  maxbond         (running max since the last stats row)
  int64    warm_end        (step at which the warm-up ramp ends; 0 = none)
  float64  t_anchor; int64 step_anchor; float64 dt_anchor   (time bookkeeping)
  uint64   soup_seed       (provenance: seed of the random soup this run descends from)
  --- per-bead arrays, N entries each, in the engine's internal (cell-sorted) slot order ---
  uint32   gid[N]          (permanent bead id of each slot)
  uint8    type[N]
  int8     mpos[N]         (position in its lipid, 0 = first head; -1 = not a lipid)
  int32    nxt[N]          (slot of the next bead in its lipid chain; -1 = none)
  float64  x[N], y[N]
  float64  vx[N], vy[N]    (half-step velocity vh; full v = vh + dt/2 f)
  float64  fx[N], fy[N]    (forces of the stored configuration, incl. the stirring force)
  char[4]  "END!"
  ```

  **Version 3** is identical except for one extra `int32 arch` (0 linear, 1 pi, 2 y, 3 bola)
  right after `nH`. It is written for branched lipid templates; linear lipids keep version 2,
  so older readers still work for them. A restart refuses a checkpoint whose mlen, nH or arch
  differs from the parameters. The template details (`lip_nT`, `lip_tie`, `r0_head`, …) are
  laws, like the a_ij, and are taken from the ini.

  Versions 2 and 3 are written only by this engine, which has no placed-structure start and no
  flood-fill supply, so every version 2 checkpoint descends from a random soup. Version 1
  files (the previous engine) are refused with an explanation. On load, the engine verifies
  that the gids form a permutation, that the lipid links are consistent, and that no bead has
  type Z. The slot order is stored on purpose: restoring it exactly makes the continuation
  bitwise identical. `tests/snapcheck.py` has a reader (`read_ckpt`, versions 2 and 3,
  returns gid-ordered arrays and full velocities).

## Determinism

For a given binary and CPU, a run is a deterministic function of its parameters, **for any
number of threads**. The ingredients:
- The force summation order is fixed by the strip decomposition (below), and the stirring
  force's net-force sum uses fixed blocks.
- The sort is a stable counting sort.
- Chemistry and the food supply are serial or use counter-based hashes, and all list merges
  are in slot order.

Verified: a restart from 3 threads to 1 thread, with every reaction, the capped feed,
stirring and the temperature cycle active, gives bitwise identical snapshots, stats, events
and checkpoint. `nsub` changes the order of floating-point summation and therefore the bits,
but not the physics.

With chemistry and the environment off, this engine reproduces the previous engine bit for
bit. Checked twice:
- soup L = 64, chem = 0, 3000 steps: snapshots and `stats.csv` identical under `cmp`;
- the full 300 000 steps of `runs/val_soup64_nochem` (old engine, 1 thread) rerun with 4
  threads: identical `stats.csv` and identical positions, types and bonds in every compared
  snapshot. Only the header `time` differs, in the last bits (8999.999999994907 vs 9000.0):
  that run accumulated t += dt, while the engine now computes t from the step.

**Lipid templates (added after the runs above).** With `lip_arch = linear`, the bonded forces,
the soup initialisation, the synthesis placement, its overlap energy and its relaxation keep
the previous code verbatim. The generic template code gives the same numbers mathematically,
but the compiler fuses multiply-adds (FMA, `-march=native`) differently, which changes the
last bits. Checked with `cmp`:
- linear, chem = 0: identical to the previous binary (memA's `membranes.ini`, the full 100k
  steps of `runs/memA_z25`: snapshots, `stats.csv` and checkpoint), and so are linear runs
  with the vent, stirring and the temperature cycle over 3000 steps;
- pi (`params/membranes.ini`): identical to team memB's engine copy, with and without
  chemistry (the full 100k steps of `runs/memB_F01_wt200_kb300`; 3000 steps with 160
  syntheses);
- **not identical**: linear runs with lipid synthesis can differ from the previous binary in the
  last bit of a new lipid's coordinates. In `soup_small.ini` this first happened at the
  synthesis of step 2550, after which the trajectories decorrelate. Copying the old chemistry
  functions verbatim does not help, because GCC inlines and contracts them differently in the
  larger source file. The physics is the same; the runs are statistically equivalent, not
  bitwise.

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
- Force zeroing and the stirring force live in a separate non-inlined function
  (`force_init`, orphaned worksharing loops). Apart from alignment padding, the pair kernel
  compiles to the same instructions as before the environment was added (checked with
  objdump).
- Bonded forces walk lipid chains through the per-slot `nxt` links (no gid→slot lookups, no
  cross-core traffic), in parallel; each bead belongs to one chain, so there are no races.
- Chemistry costs ≈ 1–2 % of a step: parallel scans, contiguous-range neighbour searches,
  and a hash-based food supply with no grid or flood fill.

Measured on the final binary against the previous engine: `soup_small.ini` with chemistry,
interleaved ABBA runs (old, new, new, old, repeated), minimum and median ms/step. Machine:
4-core Xeon VM, shared with other processes (load 1.2–2). Run-to-run scatter of the *same*
binary on this host is ±10 %.

| L (N beads) | threads | old min / median | new min / median | chemistry old → new |
|---|---|---|---|---|
| 64 (12 288) | 1 | 0.806 / 0.838 | 0.788 / 0.899 | 0.018 → 0.012 |
| 64 | 2 | 0.461 / 0.638 | 0.482 / 0.546 | 0.017 → 0.009 |
| 64 | 4 | 0.282 / 0.396 | 0.364 / 0.388 | 0.013 → 0.008 |
| 100 (30 000) | 2 | 1.213 / 1.449 | 1.224 / 1.474 | 0.038 → 0.023 |
| 128 (49 152) | 1 | 3.625 / 3.948 | 3.770 / 3.932 | 0.082 → 0.053 |
| 128 | 2 | 2.208 / 2.355 | 2.135 / 2.358 | 0.059 → 0.037 |
| 128 | 4 | 1.047 / 1.354 | 1.077 / 1.255 | 0.047 → 0.027 |
| 160 (76 800) | 2 | 3.325 / 3.446 | 3.045 / 3.435 | 0.090 → 0.056 |
| 160 | 4 | 1.738 / 2.200 | 1.941 / 1.972 | 0.075 → 0.042 |

- The totals are equal within the host noise. For a clean comparison, chem = 0 makes both
  binaries do bitwise-identical work: L = 128, 2 threads, 10 ABBA runs each gave
  2.179 ± 0.043 (old) vs 2.177 ± 0.059 ms/step (new).
- The food supply is cheaper than the flood fill it replaced: chemistry is 35–45 % faster.
- Stirring adds 0.027 ms/step at L = 128 with 2 threads, measured in isolation.
- With 4 threads, any CPU use by another process stalls every barrier (single samples of
  13 ms/step at L = 128 were seen earlier), so **use 2 threads** when sharing the machine.
- At L = 128 with 2 threads, ≈ 2.2 ms/step means ≈ 1.6·10⁶ steps or ≈ 49 000 time units per
  hour (dt = 0.03).

## Validation (tests/validate.sh, final binary: 32 of 32 checks PASS, ~90 s)

| check | result |
|---|---|
| cell/strip kernel vs O(N²) brute force (L = 9, 12.5, 23.7; nsub = 1, 4) | max abs. difference ≤ 3·10⁻¹³ (forces up to ~250), also with stirring (A = 0.7) and kT(t) = 1.3 in σ; Σ F ≈ 1e-12 |
| pair kernel, 1 vs 4 threads | bitwise identical, with and without the environment |
| fast sin(2πu) vs libm | max difference 2.3·10⁻¹⁵ |
| bonded forces vs finite differences | relative error ~10⁻⁹ |
| chain/cell integrity after repeated sorts | 0 errors |
| water L = 64, dt = 0.03, 900 t.u. | ⟨T⟩ = 0.9958 ± 0.0003 (−0.42 %), halves 0.9963 / 0.9952, max\|P\| 2.7·10⁻¹² |
| water L = 64, dt = 0.04, 900 t.u. | ⟨T⟩ = 0.9928 ± 0.0004 (−0.72 %), halves 0.9928 / 0.9927 |
| water g(r) | g(0.05) = 0.018, first peak 1.079 at r = 0.85, → 1 (soft DPD fluid) |
| restart at step 300 (3 threads → 1 thread); all reactions, capped uniform feed, stirring, kT cycle | snapshots, stats, 1466 events, final checkpoint bitwise identical |
| run killed twice by `timeout`, restarted into the same directory; vent feed (strip across the boundary), stirring, kT cycle | every output file bitwise identical to the uninterrupted run |
| soup L = 64, no chemistry, 60 000 steps | T-neighbour fraction 0.20 → 0.83, max bond 1.087, ⟨T⟩ = 0.9928 |
| food supply (`tests/feedcheck.py`, snapshots every check; every W→N change identified by gid) | see below |
| Kolmogorov stirring (water L = 48, A = 0.0015) | sine profile u0 = 0.266 ± 0.005, ν = 0.33, max\|P\| 1.3·10⁻¹², T_kin − u0²/4 = 0.9963 |
| temperature cycle (water L = 32, kT = 1 + 0.2 sin(2πt/30)) | T_kin = 0.9953 + 0.1961 sin(2πt/30 − 0.10) |
| membrane lipid: `tests/molforcetest` (10 templates: linear, pi, y, bola, ties, junction angles) | bonded forces vs finite differences ≤ 1.2·10⁻⁷ (forces up to ~165); template bonds at rest length to 2·10⁻¹⁵ |
| membrane lipid: restart at 300 (3 threads → 1 thread), `membranes.ini` physics, every reaction, feed, stirring, kT cycle | checkpoint version 3; snapshots, stats, events, final checkpoint bitwise identical |
| membrane lipid: soup L = 48, `membranes.ini` + fast synthesis (p_syn_a 0.02), 20 000 steps | 490 syntheses, max bond 1.218, ⟨T⟩ = 0.981, every molecule an intact H2T2 template |

Food-supply checks:
- Per-check conversions equal the logged `feed` counts in all 5 runs, and all conversions
  come from W.
- Uniform: positions are uniform (6×6 grid, χ² = 39 for 35 dof), and the count is
  1138 vs the binomial expectation 1143 ± 34.
- Cap 0.05: nN reaches 345 = floor(0.05·N) and never exceeds it.
- Vent: every conversion lies inside the region, exactly (disk r = 5: max distance 4.964;
  vstrip and hstrip placed across the periodic boundary: max 1.998 < 2 and 1.499 < 1.5).

Longer runs, analysed with `tests/snapcheck.py`. Quick-look PNGs from `tests/quicklook.py`
are in the run directories; these are sanity plots, not the project renderer.
- `val_soup64`: `soup_small.ini` unchanged (uniform feed, cap 0.12), 300 000 steps = 9000 t.u.
  - ⟨T⟩ = 0.9936 ± 0.0002, max bond over all steps 1.275, max|P| ≈ 1·10⁻¹¹.
  - N sits at the cap (1474) throughout.
  - Micelles by t = 150 (T-neighbour fraction 0.20 → 0.71), bilayer patches by t = 1500 (0.77).
  - The catalysts die out slowly (Ka 61 → 3, Kb 1 at t = 9000). Lipid synthesis therefore
    stops, and lipids decay from 307 to 72.
  - `tools/analyze.py`: 0 closed membranes, 0 of 6 life criteria.
- `val_soup64_nochem` (previous engine; this engine reproduces its bead data exactly, see
  "Determinism"), 300 000 steps: micelles, then coarsening into long bilayer strips; max bond
  1.136; no vesicle closed.

## Known issues and honest caveats

1. **Closed vesicles emerge only with `params/membranes.ini`; nothing else of life yet.**
   That file gives 10–13 closed bilayer vesicles with catalysts at L = 100 (see "Lipid
   templates and the membrane physics"). Their lumen is the nutrient phase, so synthesis eats
   it, and growth, division and selection have not been shown. With the SPEC starting
   parameters, soups form micelles and bilayer patches/strips but no closed vesicle
   (`val_soup64`, `val_soup64_nochem`); with N miscible in water, about 200 lipid
   architectures and parameter sets gave at most 1–3 closed vesicles at a time at L = 100
   (memA, memB). The chemistry rates still need tuning against the slow N influx into the
   lumens.
2. **Chemistry rates sit on a knife edge.** With `soup_small.ini`, catalyst replication is
   just below decay. The effective replication is 4.3·10⁻⁴ vs decay 5.2·10⁻⁴ per catalyst per
   check, because ≥ 2 N within r_cat are often missing at c_N = 0.12. Catalysts die out over
   ~9000 t.u. Raising `p_rep` to 1.5·10⁻³ (2·10⁻³) instead gives a nutrient-limited catalyst
   bloom: 694 (1219) K at t = 4500, N falling from 1474 to ~600, and lipids at 68 % (63 %) of
   all beads (L = 64, 150 000 steps). Neither is a protocell regime; this needs real tuning.
3. **Bond transients after synthesis in a crowded lipid matrix.** The only long bonds belong
   to lipids synthesised a few steps earlier, almost always the middle T–T bond, because the
   catalyst bead sits close to the middle of its new product (K–T repulsion 120).
   - Normal soups: max 1.275 over 300 000 steps (`val_soup64`).
   - Stress test of the previous engine (~2000 syntheses in 40 000 steps): max 1.33.
   - The `p_rep` = 2·10⁻³ run above, with lipids at 63 % of beads and ~1000 catalysts: one
     stats row in 1501 showed **1.514, above the SPEC limit of 1.5**. Another run at 71 %
     lipid beads reached 1.42.
   - Keep the lipid fraction well below these values, or test larger `syn_relax`/`syn_tries`,
     before trusting a lipid-saturated run.
4. **Kinetic temperature with many bonded beads** is slightly low, an integrator effect of
   the stiff bonds (ω·dt ≈ 0.42 at dt = 0.03). Without chemistry, ⟨T⟩ is 0.991 at 10 % lipid
   beads and 0.982 at 60 % (dt = 0.03); 0.996 and 0.990 at dt = 0.02. Within ±3 % for all
   tested compositions, but prefer dt = 0.03 over 0.04 once membranes dominate. With
   stirring, `T_kin` also contains the flow energy u0²/4 (see "Environment").
5. **Membrane physics caveats** (`membranes.ini`): `k_bond = 300` lowers T_kin to about
   0.985 (0.981 with many new lipids), still within ±3 %. `tools/cells.py` misses vesicles that
   touch a loose bilayer ribbon (memB counted ≈ 18 closed by eye in the 100k state of
   `runs/membranes_final`, where the detector finds 14). Its 'growth'/'death' marks without chemistry are passive
   coarsening, not life.
6. The fast path needs AVX-512 (this machine has it). Elsewhere the scalar kernel is used;
   its pair kernel is ~1.6–1.8× slower. It is tested via `-DOERCEL_SCALAR` (forcetest PASS,
   including the stirring and kT(t) checks).
