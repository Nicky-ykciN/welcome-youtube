# memA - spontaneous membranes from a random soup (tuning log)

Strategy assigned to memA: keep the single-chain lipid (H-T-T-T or other tail lengths) and tune
the repulsion matrix, angle stiffness, lipid concentration and temperature. Only `init=soup`.
Chemistry off (`chem=0`) while tuning. Nothing placed, no structure-aware rules (SPEC section 0).

Private engine copy: `runs/memA_src` (oercel.c is byte-identical to `engine/oercel.c` as of the
restart; `make -B` rebuilds a bitwise-identical binary - checked 2026-10-11 after the machine restart).
The engine source has NOT been modified by memA: every result below comes from parameters only.

Runs: `runs/memA_<name>`. Scan tooling in `runs/memA_src/scan`:
- `run.sh NAME key=value...` - run/restart one run from `params/memA_base.ini` (1 thread, `timeout 540`, walltime 520).
- `batch.sh LIST` - two runs at a time from a job list (`list_*.txt`).
- `summ.py RUN...` - per-snapshot counts (one digit per snapshot, capped at 9):
  - `strict` = cells found by `tools/cells.detect` with its defaults (closed lumen >= 16, exposure >= 0.8, bilayer wall test) - the same detector `tools/analyze.py` uses;
  - `clean` = strict cells whose membrane aggregate holds only that one lumen and <= 1.1x its wall lipids (an isolated vesicle, not part of a network);
  - `relaxed` = any enclosed solvent hole >= 4 (no exposure / bilayer test);
  - `loops` = closed rings of the hydrophobic core (`loops.py`), counts collapsed vesicles too;
  - `withK` = strict cells with >= 1 catalyst inside; "2nd-half mean" = mean over snapshots in the second half of the run.
- `vscan.py`, `look.py` (quick-look scatter with detected lumens), `stiff.py` (strip persistence length), `params_diff.py` (physics params that differ from engine defaults).
- Full summary output of all pre-restart runs: `scan/summ_prev.txt`.

Common settings unless stated: `dt=0.03, kT=1, k_bond=100, r0=0.5, f_Ka=0.005 (Ka only), chem=0, warmup=1000`,
default a-matrix (W-H 20, W-T 80, H-T 50, N-T 40, all N-x 25, K-T 120, K-H 30, rest 25).

## STATUS / SUMMARY (read this first)

**Result: closed bilayer vesicles with catalysts inside form spontaneously from a random soup.**
Final parameters: `runs/memA_src/params/membranes.ini` (run it as-is: `oercel params/membranes.ini
outdir`; it reproduces `runs/memA_z25` bit for bit). Only pair laws were changed - no engine code.

Mechanism (emergent, nothing placed): the nutrient N is made immiscible with water (a_W_N 45), so
the soup demixes into small N-rich droplets (aqueous two-phase system / coacervate-like). Lipid
heads slightly prefer N (a_N_H 22), tails repel it (a_N_T 65): lipids adsorb on each droplet and
wrap it in a bilayer (heads facing the N lumen inside and the water outside). A catalyst that is as
water-shy as its substrate (a_K_W 45) partitions into the droplets before they close.

Numbers with the final physics (100k steps, chem off): L=100 seeds 1/2/5: 9/8/6 closed vesicles
(peak 9 each), first at 22-30k steps; L=128 seed 6: 11. 100% of the vesicles contain catalysts
(8-70 each). Engine checks: T_kin 0.990 (min 0.974, max 1.019), longest bond 1.30.
Verified by eye: quick looks, `tools/render.py` micro (whole dish + zoom) and goodsell
(figs/F1_micro.png, F2_micro.png, F2_micro_cell3.png, F1_goodsell29.png, F2_goodsell28.png).

Permeation (dense snapshots, `scan/cross2.py`): catalysts never crossed an intact bilayer in 7
runs x 900 tau (80-200 catalysts inside); vesicle walls open transiently now and then (more with
excess N outside) and 2 single catalysts escaped through such openings in total. N exchange is
slow: ~0.002 N/tau per vesicle at equilibrium, ~0.06 N/tau per vesicle with the feed at cap 0.12.

Open problems (honest):
1. The lumen IS the nutrient phase (N beads, almost no W). With the SPEC example chemistry rates a
   vesicle eats its lumen in ~1500 steps and collapses (2h); at 1/100 of the rates it still deflates
   within ~3000 tau (2k). Life needs synthesis balanced with the slow N influx (p_syn ~1e-5..1e-4)
   or a different nutrient supply. Softer immiscibility (a_W_N 40-42) does not give water-filled
   lumens and forms far fewer vesicles (2l).
2. Strong N excess in the medium (feed_cap 0.20) makes naked N droplets that wet vesicles; some
   vesicles open (2f). Keep free N low.
3. Vesicles are irregular (floppy, excess membrane), some touch each other or carry bilayer flaps;
   without chemistry they slowly coarsen by fusion over ~10^4 tau (2g). tools/analyze.py can report
   false 'deling' events for a vesicle with a lumen neck that opens/closes (2d).
4. The pure-water route (N miscible) gives at most 1-3 vesicles in 100-150k steps (1a).
5. The N phase supports the vesicles: when all lumen N decays to water, 9 -> 4 vesicles stay closed
   (water-filled), the others open, and the water-shy catalysts clump together (2n).

Best checkpoints: `runs/memA_z25/ckpt.bin` (L=100, step 100000, 9 vesicles, final physics) and
`runs/memA_F2/ckpt.bin` (L=128, step 100000, 11 vesicles, final physics).

## Part 1 - reconstruction of the pre-restart study (runs done by the interrupted agent)

The notes of the first agent were lost in the machine restart. Everything below was reconstructed
on 2026-10-11 from the run directories (params.ini command-line overrides, snapshots) by re-running
`scan/summ.py` on every run. All runs completed their target steps except y07 (stopped at 55k) and
y08 (stopped at 50k), which were interrupted by the restart.

### 1a. Pure water regime (N fully miscible, a_W_N = 25): almost no vesicles

Results: cells per snapshot (strict), 2nd-half mean and final state.

| run | L | steps | changes vs defaults | strict 2nd-half mean (withK) | final |
|---|---|---|---|---|---|
| b01 | 100 | 100k | baseline (f_lip 0.10, k_angle 10) | 0.0 | 0 cells, 20 short strips |
| b02 | 100 | 100k | f_lip 0.20 | 0.1 | 0 |
| r1a | 100 | 100k | f_lip 0.30 | 0.8 | 0, one 473-lipid network |
| r1b | 100 | 100k | f_lip 0.20, k_angle 3 | 0.0 | 0 |
| r2a | 100 | 100k | f_lip 0.20, k_angle 3, a_W_H 30 | 0.0 | 0, but 9+ collapsed loops (inverted/stacked) |
| r2b | 100 | 100k | f_lip 0.20, a_W_H 30 | 0.0 | 0, 9+ loops, one 800-lipid aggregate |
| s1 | 64 | 100k | f_lip 0.15, kT 1.3 | 0.0 | 0 |
| s2 | 64 | 100k | f_lip 0.15, a_W_T 55, a_H_T 40 (weaker) | 0.0 | 0, small fragments |
| s3/s4 | 64 | 100k | f_lip 0.15, a_W_T 120, a_H_T 80, a_N_T 60, k_angle 3/10 | 0.0 | 0 |
| g01 | 64 | 60k | f_lip 0.20, k_angle 0 | 1.0 (1.0) | 1 cell area 78 |
| g02 | 64 | 60k | g01 + a_W_T 120, a_H_T 80, a_N_T 60 | 0 | 0 |
| g03/g04 | 64 | 60k | nT=4, k_angle 0 (g04 + strong a) | 0.5 / 0 | 1 / 0 |
| g05/g06 | 64 | 60k | nT=4, k_angle 3 (g06 + strong a) | 0.5 / 0 | 1 / 0 |
| g07/g08 | 64 | 60k | nT=2, k_angle 3 | 0 / 0 | many micelles, 0 |
| h01-h08 | 64 | 100k | k_angle 1-5, nT 3-5, f_lip 0.2-0.3, a_W_H 15, seed 2 | 0 - 0.8 | 0-1 cells |
| i01-i08 | 64 | 100k | warmup 30000, f_lip 0.12, a_H_H 35, softer a, kT cycle 0.3/300, seed 3, nT 5 | 0 - 0.6 | 0-1 (i06 kT-cycle: 1 empty cell) |
| j01-j04 | 64 | 150k | kT 1.1, 1.2, kT cycles amp 0.3/0.5 period 600 | 0 - 0.2 | 0-1 |
| k01/k02 | 100 | 150k | f_lip 0.20, k_angle 0 / 1 | 0.8 / 0.3 | many collapsed loops (k01: 4-8), but lumens < 16 |
| m01-m08 | 100 | 100k | k_angle 0-2, nT 3-5, f_lip 0.15-0.25, a_N_T 60, a_H_H 30 | 0 - 2.0 | m03 (nT5, k0): 2; m06 (f 0.25): 0 at end |
| n01-n08 | 100 | 100k | nT 5-7, k_angle 0-1, f_lip 0.15-0.25 | 0 - 2.6 | n01: 3 cells but one is a 692-area network hole |
| p01-p08 | 100 | 100k | f_lip 0.10-0.15, nT 3-6, k_angle 0-1 | 0 - 1.4 | 0-2 small cells, mostly without K |
| c01/c02 | 64 | 100k | f_lip 0.15, k_angle 3, catalyst affinity (a_K_W 35-40, a_K_H 20) | 0.1 / 0 | 0 |

Lessons (pure water):
1. Single-tail lipids in water form long bilayer strips that join into branched networks; strips
   almost never close into rings within 100-150k steps. Stiffer chains (k_angle 10) give straight
   strips; floppy chains (k_angle 0-1) do close loops, but the loops are **collapsed** (no water
   lumen: a ring of bilayer with nothing inside, counted by `loops` but not by the detector).
2. In 2D nothing keeps a ring inflated: water permeates freely and the bending stiffness of a
   floppy chain is too low to make it round; stiff chains do not close at all.
3. Temperature (1.1-1.3), temperature cycles, longer tails (nT 4-7), a_H_H, a_W_H 15-30, stronger
   or weaker hydrophobic repulsion: none produced more than ~2 vesicles at L=64-100. Best was
   m03/n01 (nT 5, k_angle 0) with 2-3 cells, often one being a hole inside a network.

### 1b. Aqueous two-phase regime (ATPS): N immiscible with W -> vesicles nucleate on nutrient droplets

Idea found by the first agent: make the nutrient a separate aqueous phase (a_W_N 40-55 > 25),
heads slightly prefer it (a_H_N 22), tails repel it more (a_N_T 60-75). The random soup then
demixes into small N-rich droplets in water; lipids adsorb at the N/W interface and wrap each
droplet in a bilayer (heads facing N inside and W outside). This is a pure pair-force law; it is
the known protocell route of membranes assembling around coacervate / ATPS droplets.

| run | L | f_lip | c_N | a_W_N | a_N_T | k_angle | nT | seed | strict per snapshot (5k steps apart) | 2nd-half mean cells / withK / clean | final cells (withK) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| q01 | 64 | 0.15 | 0.12 | 40 | 60 | 10 | 3 | 1 | 000000000000000000000 | 0 | 0 |
| q02 | 64 | 0.15 | 0.12 | 40 | 60 | 3 | 4 | 1 | 0... | 0 | 0 |
| q03 | 64 | 0.15 | 0.15 | 35 | 55 | 10 | 3 | 1 | 0... | 0 | 0 |
| q04 | 64 | 0.15 | 0.20 | 40 | 60 | 10 | 3 | 1 | 0... | 0 | 0 |
| q05 | 64 | 0.25 | 0.10 | 40 | 60 | 10 | 3 | 1 | 000000001111212112232 | 1.6 / 0.5 / 1.5 | 2 (1) |
| q06 | 64 | 0.20 | 0.08 | 40 | 60 | 10 | 3 | 1 | 000000000001000000001 | 0.2 | 1 (1) |
| q07 | 64 | 0.25 | 0.10 | 40 | 60 | 3 | 4 | 1 | 000000000111100121222 | 1.2 / 0.5 / 0.7 | 2 (1) |
| q08 | 64 | 0.20 | 0.10 | 35 | 55 | 10 | 3 | 1 | 0... | 0 | 0 |
| v01 | 100 | 0.25 | 0.10 | 40 | 60 | 10 | 3 | 1 | 000002221451511132232 | 2.4 / 1.9 / 0.4 | 2 (1) |
| v02 | 100 | 0.20 | 0.08 | 40 | 60 | 10 | 3 | 1 | 000000223302233344213 | 2.5 / 1.5 / 1.0 | 3 (2) |
| v03 | 100 | 0.15 | 0.06 | 40 | 60 | 10 | 3 | 1 | 000000000011202120101 | 1.0 / 0.9 / 0.7 | 1 (1) |
| v04 | 100 | 0.20 | 0.10 | 40 | 60 | 10 | 3 | 1 | 000000011002123232231 | 1.9 / 0.5 / 0.4 | 1 (0) |
| w01 | 100 | 0.20 | 0.08 | 40 | 60 | 3 | 3 | 1 | 000000012122233133433 | 2.6 / 1.9 / 0.2 | 3 (2) |
| w02 | 100 | 0.20 | 0.08 | 40 | 60 | 5 | 4 | 1 | 000000010012210110201 | 1.0 / 0.8 / 0 | 1 (1) |
| w03 | 100 | 0.20 | 0.06 | 40 | 60 | 10 | 3 | 1 | 000000101100001101033 | 0.8 / 0.4 / 0 | 3 (2) |
| w04 | 100 | 0.20 | 0.08 | 45 | 65 | 10 | 3 | 1 | 000022113546464446646 | 4.9 / 2.7 / 3.1 | 6 (4) |
| x01 | 100 | 0.20 | 0.08 | 50 | 70 | 10 | 3 | 1 | 000002457897989887788 | 8.1 / 5.4 / 1.5 | 8 (8) |
| x02 | 100 | 0.20 | 0.08 | 45 | 65 | 5 | 3 | 1 | 000034452557777877897 | 7.2 / 3.8 / 1.2 | 7 (5) |
| x03 | 100 | 0.20 | 0.06 | 45 | 65 | 10 | 3 | 1 | 000011232567663447787 | 5.9 / 3.3 / 1.4 | 7 (5) |
| x04 | 100 | 0.20 | 0.10 | 45 | 65 | 10 | 3 | 1 | 000001232688587369989 | 7.5 / 5.5 / 4.2 | 10 (8) |
| x05 | 100 | 0.20 | 0.08 | 45 | 65 | 10 | 4 | 1 | 000000111232577666766 | 5.5 / 3.9 / 1.0 | 6 (4) |
| x06 | 100 | 0.20 | 0.08 | 45 | 65 | 10 | 3 | 2 | 000012475599988999799 | 9.1 / 4.4 / 4.7 | 10 (6) |
| x07 | 100 | 0.20 | 0.08 | 55 | 75 | 10 | 3 | 1 | 000012266665798999885 | 7.6 / 4.3 / 2.6 | 5 (3) |
| x08 | 100 | 0.20 | 0.08 | 45 | 50 | 10 | 3 | 1 | 000110335645575532342 | 4.1 / 1.6 / 1.7 | 2 (1) |
| y01 | 100 | 0.20 | 0.10 | 45 | 65 | 10 | 3 | 2 | 000001211235999999978 | 8.5 / 5.8 / 2.2 | 8 (6) |
| y02 | 100 | 0.20 | 0.10 | 45 | 65 | 10 | 3 | 3 | 000112127534475769676 | 5.8 / 4.1 / 1.8 | 6 (4) |
| y03 | 100 | 0.15 | 0.075 | 45 | 65 | 10 | 3 | 1 | 000000023333423244402 | 2.8 / 1.1 / 1.8 | 2 (2) |
| y04 | 100 | 0.15 | 0.075 | 45 | 65 | 10 | 3 | 2 | 000001111133434666776 | 5.0 / 4.5 / 3.5 | 6 (5) |
| y05 | 100 | 0.20 | 0.10 | 50 | 70 | 10 | 3 | 1 | 000021246825767889997 | 7.1 / 3.9 / 2.5 | 7 (3) |
| y06 | 100 | 0.20 | 0.10 | 45 | 65 | 20 | 3 | 1 | 000001212455546474557 | 5.2 / 3.9 / 3.6 | 7 (6) |
| y07 | 100 | 0.20 | 0.10 | 50 | 70 | 10 | 3 | 2 | 000025577677 (to 55k) | 6.5 / 3.0 / 2.3 | 7 (5) at 55k |
| y08 | 100 | 0.20 | 0.10 | 45 | 65 | 20 | 3 | 2 | 00001112366 (to 50k) | 3.2 / 2.8 / 1.8 | 6 (6) at 50k |

(all ATPS runs: a_H_N = 22; L=64 runs 60k steps, snapshot every 3000; L=100 runs every 5000.)

Lessons (ATPS):
1. a_W_N >= 45 with a_N_T >= 65 is the threshold: a_W_N 40 / a_N_T 60 gives 1-3 vesicles, 45/65 to
   55/75 gives 6-10 vesicles at L=100 within 100k steps (first ones at 20-30k steps).
2. a_N_T matters independently: x08 (a_W_N 45 but a_N_T 50) only 2-4 vesicles: tails must repel
   the nutrient phase strongly, else N droplets mix with lipid tails.
3. f_lip 0.20 with c_N 0.08-0.10 is best; f_lip 0.15 (y03/y04) gives 2-6; L=64 is too small
   (the droplets coarsen to 1-2 big ones).
4. k_angle 5-20 all work; k_angle 3 (w01) worse in the a=40 series; nT=4 (x05) slightly worse.
5. Seeds 1-3 at the best point (a_W_N 45, a_N_T 65, f_lip 0.2, c_N 0.08-0.10): 6, 8, 10, 10 final cells.
6. The lumens are filled almost entirely with N (x04 final: lumens hold 115-322 N and 0-10 W each).
   That is the "aqueous" nutrient phase, not plain W. Catalysts (K-W = K-N = 25) are spread evenly,
   so most catalysts stay outside: withK is 50-70% of cells but only with 1-6 K each.
7. Quick-look images (`look.py`) at x04 50k/100k and y01 100k show round closed bilayer rings
   (heads in and out, tails between) around blue N lumens, several open "C" shaped half-shells.

## Part 2 - continuation (this session)

Plan after reconstruction:
1. Catalyst partitioning by a pair law: catalysts that like their substrate (a_K_N < a_K_W) should
   concentrate in the N droplets and therefore inside vesicles.
2. Seed replicates + small scan around the best point (a_W_N 45-50, a_N_T 65-70, k_angle 10-20, kT).
3. Measure permeation: N and K crossings of tracked vesicle membranes (frequent snapshots).
4. Chemistry-on compatibility test (uniform feed makes N in water, which should be pulled into lumens).
5. Final params -> `params/membranes.ini`, analyze.py + render.py images checked by eye.

### 2a. Batch z1 - catalyst partitioning into the N phase (P0 = f_lip 0.20, c_N 0.10, a_W_N 45, a_N_T 65, a_N_H 22, k_angle 10, nT 3, L 100, 100k steps)

| run | change vs P0 | strict per snapshot | 2nd-half mean cells / withK / clean | final cells (withK) | K per final cell |
|---|---|---|---|---|---|
| z01 | a_K_W 35 | 000030254767842445568 | 5.4 / 5.4 / 0.5 | 8 (8) | 23,16,15,16,10,4,4,2 |
| z02 | a_K_W 45, a_K_H 22 (catalyst sees W/H like N does) | 000002337849887796568 | 7.0 / 7.0 / 2.8 | 8 (8) | 26,14,15,16,12,11,7,5 |
| z03 | a_K_N 20 | 000001134356567644756 | 5.5 / 4.8 / 2.2 | 6 (5) | 7,8,8,2,5,0 |
| z04 | a_K_W 35, seed 2 | 000000323266577857756 | 6.3 / 6.3 / 2.6 | 6 (6) | - |

Result: a catalyst that dislikes plain water as much as the nutrient does (a_K_W 35-45) partitions
into the N droplets before they are wrapped, so 100% of the vesicles contain catalysts (5-26 each;
z02: 106 of 150 catalysts are inside closed vesicles at 100k). Vesicle count is not reduced.
Physical reading: an enzyme with affinity for its substrate phase (like enzymes partitioning into the
dextran phase of a PEG/dextran ATPS). Quick look `look.py` z02 at 30k/60k/100k: closed rings with
green catalysts inside, a few open half-shells. P1 := P0 + a_K_W 45 + a_K_H 22.

### 2b. Batch z2 - P1 seeds and neighbours (P1 = P0 + a_K_W 45, a_K_H 22; L 100, 100k steps)

| run | change vs P1 | strict per snapshot | 2nd-half mean cells / withK / clean | final cells (withK) | K per final cell |
|---|---|---|---|---|---|
| z02 | (P1, seed 1) | 000002337849887796568 | 7.0 / 7.0 / 2.8 | 8 (8) | 5-26 |
| z05 | seed 2 | 000011144234334364557 | 4.3 / 4.3 / 2.5 | 7 (7) | 7-18 |
| z06 | seed 3 | 000003543899799769987 | 8.1 / 7.9 / 3.9 | 7 (7) | 8-34 |
| z07 | k_angle 20 | 000011455366578978767 | 6.9 / 6.9 / 4.4 | 7 (7) | 3-31 |
| z08 | a_W_N 50, a_N_T 70, a_K_W 50 | 000002446679569995878 | 7.5 / 7.5 / 3.5 | 8 (8) | 6-17 |

Result: robust over 3 seeds (7-8 closed vesicles at 100k steps, first ones at 20-25k steps,
every vesicle holds catalysts). Lumen = 85-530 N beads, 0-22 W beads. k_angle 20 gives the most
isolated ("clean") vesicles. Quick look z06 100k / z07 50k,100k: rings closed by eye; the remaining
non-cells are N droplets with catalysts whose bilayer coat still has a gap, plus bilayer flaps
hanging off vesicles (lipid stuck in flaps rather than closing the gaps).

### 2c. Batch z3 - temperature, more material, head-nutrient affinity (P1, L 100, 100k steps)

| run | change vs P1 | strict per snapshot | 2nd-half mean cells / withK / clean | final cells (withK) |
|---|---|---|---|---|
| z09 | kT 0.9 | 000022233565777799968 | 7.6 / 7.5 / 3.1 | 8 (8) |
| z10 | kT 1.1 | 000012333664799989868 | 7.7 / 7.7 / 6.4 | 8 (8) |
| z11 | f_lip 0.24, c_N 0.12 | 000004347868765599699 | 7.3 / 7.2 / 2.0 | 10 (10) |
| z12 | a_N_H 25 (heads neutral to N) | 000000000000002231223 | 1.4 / 1.4 / 0.4 | 3 (3) |

Result: a_N_H 22 (heads slightly prefer the nutrient phase) is essential - with 25 the lipids do
not coat the droplets and only 1-3 vesicles form. kT 1.1 gives the most isolated vesicles (clean
6.4 of 7.7); kT 0.9 forms vesicles earlier but they stick together. More material (z11) gives 10.

### 2d. Permeation and catalyst crossings (chemistry off) - scan/cross2.py

Method: branch z02 and z07 at step 100000 into `memA_z02d`, `memA_z07d` (same physics) with a
snapshot every 100 steps (3 tau) for 30000 steps (900 tau, 301 snapshots). `scan/cross2.py`
detects cells in every snapshot with the analysis detector, tracks them by shared lumen beads
(bridging up to 10 snapshots of detection flicker), and classifies every solvent bead as IN(track),
OUT (in the free medium = bulk region of a raster with every lipid bead as a disk of radius 1.5,
and > 1.0 from any lipid) or ambiguous. Exit = IN(c) -> OUT while c still exists; entry = OUT ->
IN(c) with c born before the bead was last OUT (beads enclosed when a vesicle closes are not
entries); transfer = IN(c1) -> IN(c2). A first version (`cross.py`) without bridging and with a
simpler OUT definition counted many false crossings (open lumens of flickering cells counted as
outside), so only cross2 numbers are used. Outputs: `scan/cross2_z02d.json`, `scan/cross2_z07d.json`.

| run | mean cells | mean perimeter | bead type | mean inside cells | free outside | exits | entries | transfers |
|---|---|---|---|---|---|---|---|---|
| z02d | 9.1 | 272 | Ka | 104.6 | 2.9 | **0** | **0** | 14 (one dumbbell vesicle, see below) |
| | | | N | 1948 | 30.5 | 8 (+3 during detection gaps) | 8 | 229 |
| | | | W | 23.4 | 17761 | 217 (+42) | 239 | 121 |
| z07d | 7.3 | 240 | Ka | 104.4 | 2.2 | **0** | **0** | 9 (one compartmented vesicle) |
| | | | N | 1940 | 29.6 | 4 | 8 | 234 |
| | | | W | 12.3 | 17720 | 67 (+4) | 61 | 7 |

- Catalysts: 0 exits and 0 entries in 2 x 900 tau with ~105 catalysts inside closed vesicles.
  The only catalyst moves between tracked lumens (transfers) happen inside one vesicle whose lumen
  has a narrow neck that opens and closes (z02d around x 12-16, y 70-76, steps 103700-105500,
  checked in the quick-look zoom `look.py ... --zoom 0 55 35`): the two lumens are one
  compartment, nothing crosses a bilayer.
- Nutrient: N exits 4-8 per 900 tau out of ~1950 N inside: an exit rate of ~5e-6 per N per tau.
  N is held inside both by the bilayer and by the N/W immiscibility (free N in the medium is only
  ~30 beads). Entries: 8 per 900 tau, i.e. 3.3e-5 per unit membrane length per tau at a free
  outside N density of ~0.005 per unit area -> permeability ~ 7e-3 length/tau (rough). 
- Water: W exits/enters at ~0.01 per inside W per tau (lumens hold only 12-23 W).
- The tools/analyze.py checklist on z02d reports a 'deling' at 105500: that is the same dumbbell
  vesicle (neck closing), not a real fission - chemistry is off, nothing grows. Its growth/death
  rows are artefacts of lipid exchange between touching membranes for the same reason.

### 2e. Batch z4 - tail length, stiffness, catalyst amount (P1, L 100, 100k steps)

| run | change vs P1 | strict per snapshot | 2nd-half mean cells / withK / clean | final cells (withK) | K per final cell |
|---|---|---|---|---|---|
| z13 | nT 4 (H-T-T-T-T) | 000000034454544444444 | 4.2 / 4.2 / 1.7 | 4 (4) | 9-18 |
| z14 | k_angle 5 | 000000357775998898998 | 8.5 / 8.5 / 3.2 | 8 (8) | 2-24 |
| z15 | f_Ka 0.01 | 000002545556846566867 | 6.1 / 6.1 / 3.6 | 7 (7) | 12-43 |
| z16 | k_angle 15, seed 4 | 000001056754589776787 | 6.6 / 6.6 / 4.2 | 7 (7) | 6-33 |

Result: k_angle 5-20 are equivalent within seed noise (6-8 vesicles). Longer tails (nT 4) give
fewer, bigger vesicles. f_Ka 0.01 doubles the catalysts per vesicle (12-43) without hurting
formation. Fluorescence render of z07 at 100k (`tools/render.py --kind micro`, viewed): magenta
closed rings around blue nutrient lumens with green catalysts, shapes irregular (floppy, excess
membrane area), one flap of bilayer hanging off a vesicle.

### 2f. Nutrient permeation under a feed-driven gradient (z02f)

Branch of z02 at 100k: chem 1 but every reaction and decay off (p_syn, p_rep, p_ld, p_kd, p_nd = 0),
only the uniform feed (p_feed 1e-3, feed_cap 0.20). N doubles from 3000 to 6000 (the cap) within
~2000 steps; snapshot every 100 steps for 900 tau; `scan/cross2.py` -> `scan/cross2_z02f.json`.

- Catalysts: 0 exits, 0 entries (35 transfers, all inside one compartmented vesicle at x 42-50, y 84-94).
- N: 85 entries, 16 exits in 900 tau with ~1720 free N outside (vs 8/8 at equilibrium with ~30
  free N outside): uptake is driven by the outside excess but slow (~0.017 N per tau per vesicle).
- Side effect: the excess N cannot dissolve in water (a_W_N 45), it forms naked N droplets in
  the medium which wet the outer head layer of vesicles (heads like N). The number of detected
  vesicles fell from 8 to 4-6 within 900 tau (quick look z02f 100100/110000/130000: some vesicles
  now have N on both sides of a membrane that is no longer closed). Lesson for the life team:
  keep the free N in the medium low (feed_cap close to the initial c_N, feed matched to
  consumption); a strong N excess outside dissolves the compartments.

### 2g. Long-term stability without chemistry (z02L: z02 continued 100k -> 300k steps = 9000 tau)

strict cells every 5000 steps: `89799979698865667567776676656567766567655`; 2nd-half mean 6.2 cells
(6.1 with K), mean lumen area 112 (was ~75 at 100k). The vesicles persist for >= 6000 tau but
coarsen slowly by fusion (8-9 -> 5-6 vesicles, bigger lumens); every vesicle keeps its catalysts.

### 2h. Chemistry ON with the SPEC example rates (z02c) - vesicles are eaten from inside

Branch of z02 at 100k with chem 1 and the engine/SPEC example rates (p_syn_a 0.02, p_syn_b 0.06,
p_rep 1e-3, p_ld 2e-4, p_kd 5e-4, p_nd 1e-4, uniform feed p_feed 1e-3, feed_cap 0.12), 60k steps.
- strict cells every 2000 steps: `8200000000000010010011101111020` - all vesicles gone within ~2000 steps.
- events: 3303 syn, 334 rep, 2499 dlip, 391 dK, 2171 dN, feed held N at the cap (3600). Lipids 1500 -> 2300, Ka 150 -> 97.
- Quick look 100500/101500/104000/120000: each catalyst inside a pure-N lumen always has >= 4 N
  within r_cat, so a vesicle with ~15 catalysts converts its ~300 lumen N into ~75 lipids within
  ~1000-1500 steps; the lumen empties, the new lipids fill the vesicle and it collapses into a lipid
  mass with the catalysts stuck in it (a_K_H 22 makes them stick to heads). The feed cannot refill
  the lumen through the bilayer that fast (measured influx 0.01-0.1 N per tau per vesicle, see 2d/2f).
- tools/analyze.py on z02c: 202 of 3303 syntheses happened inside a lumen (before the collapse) and
  181 new lipids were in a cell wall at the next snapshot - metabolism into the wall does work, it is
  just ~100x too fast for the nutrient supply.
=> For the life team: with these membranes the synthesis must be limited by the nutrient influx,
   i.e. p_syn ~ 1e-4..1e-3 (not 0.02) or the lumen store is consumed and the cell collapses.

### 2i. Bilayer permeability vs a_N_T / a_W_N (branches of z02 at 100k, feed-only gradient)

All four: chem 1 with every reaction and decay off, uniform feed p_feed 1e-3, feed_cap 0.15
(N 3000 -> 4500), 30k steps, snapshot every 100 steps, `scan/cross2.py` (json in scan/cross2_<run>.json).

| branch | law change at 100k | mean cells | N inside / free outside | N exits (+gap) | N entries | Ka exits | Ka entries | notes |
|---|---|---|---|---|---|---|---|---|
| z02g65 | none (control) | 6.2 | 1528 / 752 | 6+4 | 291 | 0 | 13 | the 13 Ka 'entries' are one event: an open compartment with catalysts closed and merged with a small vesicle at step 111200 (seen with `scan/evlook.py`), not a bilayer crossing |
| z02g50 | a_N_T 50 | 1.9 | 507 / 615 | 11 | 66 | 0 | 0 | vesicles fall apart: N mixes into the tail core |
| z02g40 | a_N_T 40 | 0.4 | 77 / 482 | 0 | 4 | 0 | 0 | vesicles destroyed |
| z02gW40 | a_W_N 40, a_K_W 40 | 6.7 | 1819 / 872 | 41+12 | 141 | 1 | 1 | the Ka exit and entry both went through transient openings of a membrane fold (evlook: wall opens for ~200 steps at 111000-111300, reseals with the catalyst outside) |

Conclusions: a_N_T must stay high (65): lowering it to 50 dissolves the vesicles within 900 tau.
Softer immiscibility (a_W_N 40) makes N exchange ~5x faster but the walls show transient openings
that let a catalyst through. In the a_W_N 45 / a_N_T 65 regime: 0 catalyst bilayer crossings in
4 runs x 900 tau (z02d, z07d, z02f, z02g65); every catalyst move between compartments was a
membrane rearrangement (neck, closure or fusion), checked by eye.

### 2j. Batches z5/z6 and the final-parameter replicate

| run | change | strict per snapshot (5k apart) | 2nd-half mean cells / withK / clean | final cells (withK) | K per final cell |
|---|---|---|---|---|---|
| z21 | P1 + a_N_T 55 | 000010344467964444666 | 5.6 / 5.6 / 2.7 | 6 (6) | - |
| z22 | P1 + a_N_T 50 | 000003322346366541422 | 3.9 / 3.9 / 1.8 | 2 (2) | - |
| z23 | P0 + a_K_W 45 (a_K_H back to the SPEC 30) | 000001233558989879998 | 8.4 / 8.4 / 5.5 | 8 (8) | 2-26 |
| z24 | z23, seed 2 | 000012244558998868778 | 7.6 / 7.6 / 3.5 | 8 (8) | 3-26 |
| z25 | z23 + k_angle 15, f_Ka 0.01 | 000003233545666687769 | 6.4 / 6.4 / 4.0 | 9 (9) | 10-51 |
| z26 | z25, seed 2 | 000000134699888867898 | 8.0 / 8.0 / 2.3 | 8 (8) | 8-48 |
| F1 | `params/membranes.ini` (= z25 physics), seed 5, snapshot every 1000 | (every 5k) 000000245234596687576 | 6.0 / 6.0 / 2.5 | 6 (6) | - |

Result: a_K_H 22 is not needed - a_K_W 45 alone puts the catalysts in the droplets, so the SPEC
value a_K_H 30 is kept. a_N_T below 65 weakens vesicle formation (55: 6, 50: 2-4). Final choice
written to `params/membranes.ini`: f_lip 0.20, c_N 0.10, f_Ka 0.01, H-T-T-T, k_angle 15,
a_W_N 45, a_N_H 22, a_N_T 65, a_K_W 45 (rest SPEC/engine defaults), kT 1, dt 0.03.

### 2k. Slow chemistry on the final membranes (z25s)

Branch of z25 at 100k: chem 1 with all example rates divided by 100 (p_syn_a 2e-4, p_syn_b 6e-4,
p_rep 1e-5, p_ld 2e-6, p_kd 5e-6, p_nd 1e-6), uniform feed p_feed 1e-4, feed_cap 0.11, 100k steps.
- lipids 1500 -> 2055 (595 syn, 40 dlip), Ka 302 -> 314, N held at the cap (3300).
- strict cells (every 2000 steps) `978667887677774535657766666653533247464736564454564`: from 9 to 4-6;
  relaxed holes stay at 7-9, but 'clean' (isolated) vesicles drop to 0.
- tools/analyze.py: criterion 2 (metabolism) = JA: 213 of 595 syntheses inside a lumen, 197 new
  lipids in a cell wall at the next snapshot (Spearman rho 0.81 between syntheses and new wall lipids per cell).
- Quick look 100k/150k/200k: the vesicles slowly empty: the lumen N is turned into membrane faster
  than N re-enters (consumption ~0.8 N/tau in the box vs measured influx ~0.1-0.3 N/tau), so the
  vesicles deflate into folded membranes with the catalysts clustered inside the folds.
=> Even at 1/100 of the example rates the lumen store runs down within ~3000 tau. In this regime
   the lumen IS the nutrient phase and W cannot replace it fast; growth needs either still slower
   synthesis or a lumen that also holds water (then the uniform feed W->N works inside the cell).
   Batch z7 tests softer immiscibility for mixed lumens.

### 2l. Batch z7 - softer immiscibility (to get water into the lumens) fails

Base: membranes.ini physics (k_angle 15, f_Ka 0.01, a_N_T 65, a_N_H 22) with a_W_N = a_K_W lowered.

| run | change | strict per snapshot | 2nd-half mean cells | final cells (withK) | lumen content |
|---|---|---|---|---|---|
| z27 | a_W_N 40, a_K_W 40 | 000000000002101022301 | 1.1 | 1 (1) | 433 N, 15 W |
| z28 | a_W_N 40, a_K_W 40, seed 2 | 000001000210001012222 | 1.0 | 2 (2) | 192 N / 7 W; 116 N / 5 W |
| z29 | a_W_N 42, a_K_W 42 | 000000022203244251344 | 2.9 | 4 (4) | 229-316 N, 0-7 W |
| z30 | a_W_N 40, a_K_W 40, a_N_T 75 | 000000000011001211223 | 1.3 | 3 (2) | one pure-water vesicle (257 W, 2 N) next to an N vesicle |

Result: vesicle formation needs a_W_N >= 45 (with a_K_W raised alongside: 42 gives 3-4, 40 gives 1-2);
softening the immiscibility does not produce mixed W/N lumens, the lumens stay N. Kept a_W_N 45.

### 2m. Final physics (membranes.ini = z25): production size and crossings

L=128 (memA_F2, seed 6, 2 threads, 2.04 ms/step): strict cells every 4000 steps
`00000000056459675979967999` -> 11 closed vesicles at 100k, all 11 with catalysts, first at 30k;
tools/analyze.py: 22 self-formed cells, 100% bilayer walls; T_kin 0.990 (min 0.977, max 1.015),
longest bond 1.217. Fluorescence render (figs/F2_micro.png, viewed): ~11 closed magenta rings with
GFP catalysts and nutrient lumens, plus a few open strips.
L=100 replicate F1 (seed 5): 6 vesicles at 100k (peak 9), all with catalysts; T_kin 0.990, max bond 1.223.

Crossings on the final physics (branches of z25 at 100k, 30k steps, snapshot every 100, cross2.py):

| branch | condition | mean cells | Ka inside | Ka exits | Ka entries | N in / free out | N exits (+gap) | N entries | W exits / entries |
|---|---|---|---|---|---|---|---|---|---|
| z25d | equilibrium, chem off | 7.4 | 197 | **0** | **0** | 1674 / 154 | 10 | 11 | 117 / 115 |
| z25g | feed only to feed_cap 0.12 | 6.6 | 198 | 1 | 35 (2 mass events) | 1722 / 478 | 7+32 | 344 | 112 / 161 |

Both z25g catalyst events were checked by eye (figs/ev_z25g_exit.png, figs/ev_z25g_mass.png):
- the 1 'exit' (bead 6065, step 117300): the vesicle wall had a gap at 115800 with the catalyst
  sitting in it; the wall closed with the catalyst on the outside - a leak through a transient
  opening, not a crossing of an intact bilayer;
- the 2 mass 'entries' (10 and 24 catalysts): a vesicle opened a wide pore for ~1000 steps
  (longer than the 10-snapshot bridging window) and resealed; its catalysts never left.
=> Catalysts never crossed an intact bilayer in any of the 7 dense runs (7 x 900 tau, 80-200
   catalysts inside). Vesicle walls do open transiently, more often when the feed raises free N in
   the medium; through such openings 2 single catalysts escaped in total (z02gW40, z25g).
=> N influx at the default feed cap (0.12): 344 entries in 900 tau for ~6.6 vesicles, i.e.
   ~0.06 N per tau per vesicle; at equilibrium the exchange is ~0.002 N per tau per vesicle.

### 2n. Do the vesicles survive when their N lumen turns into water? (z25w)

Branch of z25 at 100k: chem 1 with only nutrient decay N -> W (p_nd 1e-3 per check; everything else
0, feed none), 40k steps (1200 tau). N 3000 -> 55.
- strict cells (every 2000 steps) `965544235244634333244`: 9 -> 4 vesicles. The 4 survivors are
  water-filled (84-643 W, 0-8 N, 12-68 catalysts each); the others opened into C-shaped strips.
- Quick look (figs/z25w.png): without N the water-shy catalysts (a_K_W 45) clump into tight
  catalyst clusters inside and outside the vesicles.
=> The N phase templates and supports the vesicles; once a vesicle has formed it can survive with a
   water lumen (about half did here), but smaller ones open. Catalysts then aggregate.

## Part 3 - run index of this session and tools

New runs (all `runs/memA_<name>`, chem 0 unless stated): z01-z30 (soup scans, 100k steps, L 100),
z02d/z07d/z25d (dense snapshots, equilibrium), z02f/z02g65/z02g50/z02g40/z02gW40/z25g (dense,
feed-only gradients), z02L (z02 to 300k), z02c (example chemistry), z25s (chemistry /100),
z25w (N decay only), F0 (`membranes.ini` as-is, = z25 bitwise), F1 (seed 5, snapshot every 1000),
F2 (L 128, seed 6, 2 threads). Job lists: `scan/list_z1..z7.txt`, `scan/list_pb.txt`.

New tools in `scan/`: `branch.sh` (continue a run's checkpoint into a new run with overrides),
`cross2.py` (membrane crossings per bead type with tracking and gap bridging; `cross.py` is the
superseded first version), `evlook.py` (zoomed panels following one bead around an event),
`params_diff.py` (physics params differing from engine defaults). Figures: `runs/memA_src/figs/`.

Next steps I would take (for a successor):
1. Life-team handoff: synthesis must be balanced with the slow N influx (p_syn ~1e-5..1e-4), or
   use the open vesicles' lumen-to-water conversion (2n) with a supply that acts inside the lumen.
2. Rounder, less sticky vesicles: try kT 1.1 (z10 gave the most isolated vesicles) with 2-3 seeds.
3. Look for division routes: dumbbell vesicles with a lumen neck that opens and closes occur
   spontaneously (2d), excess membrane area from synthesis could pinch them off.
