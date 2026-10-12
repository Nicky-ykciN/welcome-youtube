# lifeA - emergent growth and division: tuning log

Agent lifeA. Strategy: the internal route (balance of lipid synthesis vs lumen growth / excess
membrane area, osmotic effects of impermeable catalysts, permeability, decay). NO environmental
forcing (stir_A = 0, kT_amp = 0). Only laws and environment may be tuned (SPEC section 0).

- Private engine copy: /home/user/welcome-youtube/cel/runs/lifeA_src (copied from engine/ at
  start; binary md5 b727b932 = the installed engine).
- Runs: /home/user/welcome-youtube/cel/runs/lifeA_*
- Final params (target): runs/lifeA_src/params/life.ini
- Start states: init=soup with params/membranes.ini physics, or restart from
  runs/membranes_final/ckpt.bin (step 100000, L=100, seed 1, 14 detected vesicles).

## 0. STATUS / resume pointer (update after every batch)

- Session 1 started 2026-10-12 04:25.
- 08:45 status: 2 genuine emergent divisions verified by eye + catalyst identity (c06 closed mode,
  u3 with feed), plus a 3rd budding event in g03. All are BUDDING of big cells with excess membrane;
  rate ~1 per 100k steps per L=100 box; daughters do not yet grow and divide again (no sustained cycle).
  Engine change: r0_tie (tie length of the pi lipid), default = old behaviour (bitwise checked).
  Best regime so far: r0_tie 0.75-0.85 + uniform feed 3e-4 cap 0.13 + slow chemistry (syn 2e-4,
  rep 5e-5, ld 1e-5, kd 1e-5) from runs/membranes_final/ckpt.bin. Running: y1 (same laws from soup),
  y2 (long run 100k->400k from the checkpoint, r0_tie 0.8, with Kb mutation mu 0.02).
  Evidence renders: /tmp/claude-0/renders/c06r_strip.png (tools/render.py micro of the c06 division).

## 1. Engine changes in this private copy

- none yet

## 2. Tooling (runs/lifeA_src/scan)

## 3. Experiment log

### Tooling written (session 1)
- `scan/run.sh NAME INI k=v...`: one <=540 s chunk of runs/lifeA_NAME (continues from its ckpt.bin if present).
- `scan/batch.sh JOBS`: 2 concurrent 1-thread jobs from a job list (`scan/jobsNN.txt` = exact commands of every batch).
- `scan/mon.py RUN [--every k] [--full]`: tools/cells.detect per snapshot (cache RUN/lifeA_cache/), timeline
  (cells, cells with K, K inside/total, lumen areas, wall lipids/all lipids, N inside/total, largest aggregate)
  and bead-identity split detection (lumen solvent beads by gid; SPLIT SEP = daughters in different membrane
  aggregates, SHARED = same aggregate).
- `scan/perm.py RUN --lag S`: membrane crossings of N (exits/entries of persisting cells, > 2.5 from any lumen).
- `scan/look.py RUN --steps ... --at X Y --w W [--cells]`: quick bead plots (W omitted).
- params: `params/base.ini` = membranes.ini + threads 1, warmup 0; `params/chem0.ini` = base + chem=1 with
  every rate explicitly 0 (each run sets its rates on the command line; see jobs files).

### Batch p00 - permeability vs a_T_N (chem 0, from membranes_final 100k, 20k steps, snap 500)
| a_T_N | cells at 100k -> 120k | N exits / entries per unit perimeter per tau |
|---|---|---|
| 120 (as is) | 14 -> 13-17 | 2.1e-4 / 3.7e-4 |
| 90 | 14 -> 12-16 | 1.7e-4 / 2.1e-4 |
| 70 | 14 -> 5 (vesicles break up) | 2.9e-4 / 6.5e-4 |
| 50 | 14 -> 2-5 (destroyed) | - |
Lesson: N "permeation" is NOT through the tail core (independent of a_T_N in 90-120); it goes through
transient wall defects. Lowering a_T_N below ~90 destroys the N-lumen vesicles (N then wets tails:
monolayer coating of N droplets is preferred over a bilayer).

### Batch c01-c04 - chemistry on, fast synthesis (30k steps from 100k, snap 1000)
| run | p_syn_a | feed | other | cells 100k -> 130k | syn events |
|---|---|---|---|---|---|
| c01 | 2e-3 | none | | 14 -> 1 (110k) -> 7 empty-ish | 712 |
| c02 | 2e-3 | uniform 1e-3 cap 0.15 | | 14 -> 1-5 | 1242 |
| c03 | 5e-4 | uniform 1e-3 cap 0.15 | a_T_N 90 | 14 -> 4 | 442 |
| c04 | 5e-4 | uniform 1e-3 cap 0.15 | a_W_N 35 | 14 -> 3 | 424 |
N entries with feed: 0.6-2.2e-3 per perimeter per tau (~0.02-0.04 N/tau per vesicle) vs consumption at
p_syn_a 5e-4 with ~10 K: ~0.07 N/tau per vesicle. Images (c01 zoom): new lipids made inside the N lumen
do not integrate cleanly into the inner leaflet; they form a disordered inner multilayer, the lumen is
eaten and the vesicle becomes part of the ribbon network. With the feed, free N in the water wets the
outer head layers and vesicles merge into networks of N pockets.

### Batch g01-g04 - slow synthesis 100k steps (100k -> 200k, snap 2000)
| run | rates | cells (every 10k) | K total | notes |
|---|---|---|---|---|
| g01 | syn 1e-4 rep 5e-5 ld 1e-6 kd 2e-6, feed 1e-4 cap 0.11 | 14 9 7 11 9 6 4 5 5 7 11 | 300 -> 489 | lipids 1500 -> 1845; no splits |
| g02 | syn 1e-4, feed 3e-4 cap 0.13 | 14 12 11 7 4 10 7 5 6 6 4 | -> 465 | cells decline |
| g03 | syn 3e-4 rep 1e-4, feed 3e-4 cap 0.13 | 14 8 8 11 11 11 8 2 2 0 3 | -> 705 | lipids 1500 -> 2627, network |
| g04 | chem 0; "aqueous lumen" laws at restart: a_W_N 25, a_T_N 60, a_W_T 100, a_W_K 25 | 14 -> 0 at 110k | | pi1 bilayers fall apart into small aggregates (largest 50-80) with a_W_T 100 |

### Batch h01-h04 - head/N affinity (spontaneous-curvature idea), 60k steps from 100k, snap 1000
Rates: p_syn_a 2e-4, p_rep_a 5e-5, p_ld 1e-6, p_kd 2e-6, feed uniform 1e-4 cap 0.11.
| run | change | cells (every 6k) |
|---|---|---|
| h01 | a_H_N 26 | 14 11 6 10 4 7 8 5 7 7 3 |
| h02 | a_H_N 30 | 14 11 6 9 9 5 6 2 4 0 1 |
| h03 | a_H_N 35 | 14 13 7 4 3 3 3 4 1 4 3 |
| h04 | a_H_N 30, a_W_H 15 | 14 9 6 4 1 1 0 1 1 0 1 |
Lesson: making heads dislike N (positive spontaneous curvature from the N/W asymmetry) only destroys
vesicles; no splits. g01d (dense snapshots 200k-230k of g01): vesicles are embedded in a network of
ribbons and N pockets; K-rich lumens grow (K 53 -> 73), no split seen.
Track tool `scan/track.py` (lumen-bead-identity tracks, splits/merges) added.

Thinking at this point: the N-lumen ATPS world is an "active emulsion" (N made from W outside by the
uniform feed, N consumed inside droplets by K / p_nd). Zwicker et al. (Nat. Phys. 2017) showed such
droplets can grow and DIVIDE by a shape instability. Next: test whether bare N droplets (no lipids)
divide in this DPD with feed outside + degradation inside (batch z).

### Batch z1-z4 - bare active emulsion (L=64 soup, NO lipids, N droplets; feed W->N + N decay), 100k steps
| run | p_feed / p_nd | N droplets (>= 15 beads) | splits / merges (droptrack.py) |
|---|---|---|---|
| z1 | 1e-4 / 1e-3 | 15-22, sizes 30-140 beads, NO coarsening over 100k steps (size control) | 0 / 80 |
| z2 | 1e-3 / 1e-2 | 1-8 small droplets (15-27) | - |
| z3 | 3e-3 / 3e-2 | none (N too short-lived) | - |
| z4 | 5e-4 / 1e-2 | none | - |
Lesson: turnover suppresses coarsening (Zwicker-like size control) but droplets do NOT divide; their
number is kept by nucleation + evaporation + merging. N/W tension is far too strong for a shape instability.

### Batch e - membrane affinities with chemistry (100k steps from 100k, snap 1000)
Rates: p_syn_a 1.5e-4, p_rep_a 5e-5, p_ld 1e-6, p_kd 2e-6, feed uniform 1e-4 cap 0.11.
| run | change | cells every 10k | splits (track.py SEP) | look |
|---|---|---|---|---|
| e02 | a_H_K 15 | 14 9 12 6 7 7 5 5 4 5 2 | 0 | |
| e03 | a_H_K 10 | 14 9 7 7 8 4 5 3 8 6 5 | 0 | K coat both faces of membranes and glue them: multi-lobed foams |
| e04 | a_H_H 20 | 14 16 8 13 13 4 10 8 7 9 12 | 0 | |
| e06 | a_H_H 18, a_H_N 24 | 14 14 13 12 13 8 10 11 9 11 8 | 0 SEP, 3 SHARED (compartments in one aggregate) | |
h03 look (a_H_N 35): N/K droplets are expelled from the membranes (naked droplets + empty rings).

### Batch c05-c06 - CLOSED system (no feed, no replication, no decay), slow synthesis, 60k steps from 100k
| run | p_syn_a | cells every 6k | notes |
|---|---|---|---|
| c05 | 2e-4 | 14 13 16 11 10 13 9 7 4 6 7 | 2 SHARED splits (compartments) |
| c06 | 5e-4 | 14 12 9 7 4 4 3 5 3 8 3 | 3 SHARED splits; **FIRST EMERGENT DIVISION SEEN** |

**c06 division (verified by catalyst identity and by eye, /tmp/claude-0/c06_split2.png):** a vesicle that
closed by itself around an open N/K pocket (110k: cell at (46,45), A81, K24) grows membrane while
synthesis eats its lumen -> elongates (122k, lobe) -> neck (124-126k) -> two compartments (127k) ->
two lobes pull apart (128-131k) -> 134k: two SEPARATE closed vesicles in different membrane aggregates:
(44,44) A25 L59 K13 and (29,38) A21 L49 K10; their catalysts (gids) come from the same parent cell
(11 + 8 of them were inside that parent at 122k; the other 2 + 2 were in its undetected lobe).
Mechanism: excess membrane area. Synthesis converts lumen N (area) into membrane lipids (perimeter),
so the reduced area 4 pi A / P^2 falls, the vesicle elongates and pinches. No feed = no refill, so this
is not yet sustainable (lumens shrink every generation).
Tool: `scan/kid.py RUN STEP_A STEP_B` lists, for each cell at STEP_B, where its catalysts were at STEP_A.
NEXT: (1) automatic division detector by catalyst lineage (divs.py); (2) replicate c06 (seeds);
(3) add replication + a weak N supply so daughters can refill and divide again.
Tool: `scan/divs.py RUN` - automatic division detector by catalyst lineage (parent cell whose catalysts end
up in >= 2 detected cells in DIFFERENT membrane aggregates within 15 frames; persistence + pre-history
reported). On c06 it finds the division (parent @126k -> daughters @134k); the daughters are lost after
1-4 more frames: without N supply they eat their lumens and collapse (closed system).

### Batch c07-c10 (60k steps from 100k, snap 1000)
| run | rates | cells every 6k | divisions (divs.py) | notes |
|---|---|---|---|---|
| c07 | syn 5e-4, rep 2e-4, closed | 14 9 4 5 2 2 4 4 5 9 4 | 0 | K 300 -> 582; lumens eaten |
| c08 | syn 5e-4, rep 1e-4, feed 1e-4 cap 0.11 | 14 9 5 6 7 4 5 4 2 5 3 | 0 | N stays OUTSIDE (dispersed + small droplets); K clump into dense blobs inside collapsed vesicles (a_W_K 45) |
| c09 | syn 1e-3, closed | 14 6 1 3 2 1 4 7 3 1 4 | 0 | |
| c10 | = c06, restart_reseed seed 2 | 14 13 11 8 5 6 2 3 3 4 1 | 0 | the c06 division is a rare event |
Lesson: N influx through the membrane is the bottleneck: with the feed, N accumulates outside and
the lumens are still eaten. Next: batch k = membrane N-permeability (a_W_T 150/120, a_N_K 15 osmotic
binding of N by catalysts), feed 3e-4 cap 0.13, no synthesis, measure entries with perm.py.

### Batch k - N entry vs membrane laws (feed 3e-4 cap 0.13, no synthesis, 25k steps from 100k, snap 500)
| run | change | cells at 125k | N entries per unit perimeter per tau |
|---|---|---|---|
| k04 | reference | 11 | 9.0e-4 |
| k01 | a_W_T 150 | 9 | 5.7e-4 |
| k02 | a_W_T 120 | 8 | 2.4e-4 |
| k03 | a_N_K 15 (catalysts bind N) | 9 | 1.1e-3 |
Lesson: entry stays ~1e-3 per unit length per tau, i.e. ~0.02-0.03 N/tau per vesicle. A vesicle needs
~300 N per doubling -> ~10^4 tau = 3-4e5 steps per generation even if synthesis is tuned exactly to it.
Softer tails (lower a_W_T) make entry slower, not faster.

### Batch q - N miscibility x tail repulsion (chem 0, 20k steps from 100k)
| run | a_W_N / a_T_N | cells at 120k | entries/perim/tau |
|---|---|---|---|
| q01 | 40 / 70 | 5 | 4.5e-4 |
| q02 | 40 / 55 | 0 | - |
| q03 | 35 / 70 | 2 | 8.2e-4 |
| q04 | 35 / 55 | 0 | - |
Lesson: every step towards an N-permeable tail core destroys the N-lumen vesicles. In this world the
membrane is effectively impermeable; N enters only through rare wall defects (~1e-3 per length per tau).

Idea now: make DIVISION easier rather than influx faster. Inner-leaflet adhesion: if heads attract
each other more than they like N (a_H_H < a_H_N), the two inner leaflets of a deflating vesicle zip
together and cut the lumen in two (each part fully wrapped by its own bilayer). e06 (a_H_H 18,
a_H_N 24) kept the most cells of batch e and showed 3 compartment splits. Test in the closed c06 mode.

### Batch d - inner-leaflet adhesion in the closed c06 mode (syn 5e-4, no feed, 60k steps)
| run | change | cells every 6k | divisions |
|---|---|---|---|
| d1 | a_H_H 18, a_H_N 24 | 14 11 11 12 10 8 8 7 5 3 4 | 0 |
| d2 | a_W_H 18, a_H_H 20, a_H_N 24 | 14 10 10 7 4 2 6 6 9 6 5 | 0 |
| d3 | a_H_H 18 | 14 10 10 8 9 6 8 4 1 4 6 | 0 |
| d4 | a_W_H 18, a_H_H 16, a_H_N 24 | 14 14 12 12 8 7 6 8 5 9 6 | 0 |
Lesson: head adhesion does not produce divisions.

### Batch w - "water lumen" test: make N (and K) water-miscible at restart (chem 0, 20k steps)
| run | change | cells at 115k / 120k |
|---|---|---|
| w1 | a_W_N 25, a_W_K 25 | 1 / 3 (W floods in: c0 N70 W416) |
| w2 | + a_T_N 80 | 1 / 0 |
| w3 | + a_T_N 60 | 0 / 1 |
| w4 | + a_T_N 60, a_W_T 150 | 0 / 0 |
Lesson: these pi1 vesicles exist ONLY as coats of N droplets; without the N/W immiscibility they open
into strips. The lumen must stay the N phase. So uptake must work with N-phase lumens.
Next idea: membranes that open only where an N droplet touches them from outside (bilayer between two
N phases is weaker when a_T_N is lower): droplet capture = N uptake. Test a_T_N 90/80 with feed, no synthesis.

### Batch k05-k08 - lower a_T_N + feed 3e-4 cap 0.13, no synthesis (40k steps)
| run | a_T_N | cells @140k | Nin 100k -> 140k | entries/perim/tau |
|---|---|---|---|---|
| k05 | 90 | 3 | 1152 -> 224 | 1.6e-3 |
| k06 | 80 | 5 | -> 522 | 1.0e-3 |
| k07 | 90 (feed 1e-3 cap 0.16) | 8 | -> 1349 | 7.6e-4 |
| k08 | 100 | 8 | -> 1494 (lumens grow: mean A 31 -> 71) | 5.4e-4 |
k08 looks tidier (separate vesicles, lumens growing mostly by fusion/capture of N droplets).

## ENGINE CHANGE 1 (private copy): `r0_tie`
New law parameter `r0_tie` (pi lipid): rest length of the tie bond between the two tail beads
(default -1 = r0_head, i.e. the old rectangle). r0_tie < r0_head = cone-shaped lipid (heads wider),
> r0_head = inverted cone. Template geometry adapted (first tail bead at bond length r0 from its head).
Verified: with the default, the new binary is bitwise identical to the installed engine (restart from
membranes_final, 3000 steps with 424 syntheses: snapshot, ckpt, events, stats identical under cmp).
Original source kept as orig_oercel.c, original binary as oercel_orig.

### Batch f - division propensity screen, CLOSED mode (p_syn_a 5e-4, no feed/rep/decay, 60k steps)
| run | change | cells every 10k (100k-160k) | largest aggregate @160k | divisions |
|---|---|---|---|---|
| f01 | r0_tie 1.0 (inverted cone) | 14 14 9 5 1 0 1 | 2110 = ALL lipids (one network) | 0 |
| f02 | r0_tie 0.45 (cone) | 14 0 0 0 0 1 0 | 49 (membranes fall apart into micelles) | 0 |
| f03 | lip_tie 0 | 14 11 7 6 6 5 10 | 1453 (network) | 0 |
| f04 | k_bond 150 | 14 10 7 3 0 2 3 | 270 | 0 |
| f05 | a_H_T 35 | 14 13 13 5 2 5 5 | 1315 | 0 |
| f06 | r0_head 0.9 | 14 14 6 7 1 1 2 | 765 | 0 |
| f07 | a_W_T 300 | 14 6 6 5 4 6 4 | 507 | 0 |
| f08 | c06 replicate, seed 3 | 14 13 6 1 1 4 3 | 290 | 0 |
Lessons: (1) the closed mode is a death spiral: every vesicle eats its lumen in ~30-40k steps and
collapses; the c06 division (1 in 3 seeds x ~10 vesicles) is rare. (2) r0_tie is a strong knob:
0.45 -> micelles, 1.0 -> everything fuses into one network; the useful range is near 0.7.

### Batch s - a_T_N 100 + feed + synthesis (100k steps from 100k, p_ld 1e-5, p_kd 1e-5)
| run | rates | cells every 10k | divisions |
|---|---|---|---|
| s1 | syn 2e-4 rep 5e-5, feed 3e-4 cap 0.13 | 14 11 7 5 5 6 6 8 6 9 3 | 1 unconfirmed (161k, daughters K45 + K8, lost next frame) |
| s2 | syn 5e-4 rep 1e-4, feed 3e-4 cap 0.13 | 14 11 7 5 2 4 4 2 2 5 0 | 0 |
k08 tracks: individual cells do NOT grow (T56 A71 -> 70, T63 A87 -> 90 over 20k steps); the mean-area
rise came from fusions. Conclusion so far: the lumen cannot grow because the membrane is a barrier
(all reactions conserve beads; only crossings add lumen beads, and crossings are rare defects).
Next idea: mildly cone-shaped lipids (r0_tie slightly < r0_head) -> cheaper pore edges -> more
transient pores (permeability) and positive monolayer curvature (budding). Scan r0_tie 0.55-0.8.
| s3 | syn 2e-4 rep 5e-5, feed 1e-3 cap 0.15 | 14 6 6 6 4 7 2 7 5 3 3 | 0 |
| s4 | syn 5e-4 rep 1e-4, feed 1e-3 cap 0.15 | 14 8 5 5 4 2 2 5 4 0 2 | 0 |

### Batch t - tie length scan with feed 3e-4 cap 0.13, no synthesis (30k steps from 100k, snap 500)
| run | r0_tie | cells @115k/120k/125k/130k | Nin @130k (from 1152) | N entries/perim/tau |
|---|---|---|---|---|
| t055 | 0.55 | 1 2 2 1 | 78 | 1.1e-4 |
| t060 | 0.60 | 4 4 2 2 | 183 | 8.3e-4 |
| t065 | 0.65 | 9 7 8 8 | 1538 | 9.1e-4 |
| t080 | 0.80 | 14 16 13 11 | 2256 @120k, 1572 @130k | 6.0e-4 |
Lesson: cone-shaped lipids (r0_tie < 0.7) destabilise the vesicles. Mild inverted cone (0.8) keeps more
cells AND their lumens take up N fast (Nin doubles in 20k steps, ~0.09 N/tau per cell, 4x the defect
rate): capture/fusion of nucleated N droplets (inverted-cone lipids favour fusion, like PE lipids).

### Batch u - r0_tie 0.75-0.85 with feed 3e-4 cap 0.13 and slow chemistry (150k steps from 100k)
p_ld 1e-5, p_kd 1e-5. u1: r0_tie 0.8, syn 1e-4 rep 3e-5 -> 7-14 cells kept for 150k steps, lumens grow
(mean A 31 -> 50-70), K 300 -> 426, but the cells are pockets of a growing membrane network ("foam",
largest aggregate ~1000 lipids); 1 unconfirmed split. u2: r0_tie 0.8, syn 3e-4 -> network of 2500 lipids,
small cells, 1 unconfirmed split. (u3/u4 see below.)
u3: r0_tie 0.75, syn 2e-4 rep 5e-5 (stopped at 222k by the chunk walltime): cells 14 16 6 7 7 1 12 3 6.
u4: r0_tie 0.85, syn 2e-4 rep 5e-5 (stopped at 220k): 14 15 14 15 15 10 9 5 6, network grows to 2000 lipids.

**Second emergent division (u3, verified by eye + catalyst identity, /tmp/claude-0/u3div.png):** a big cell
(125k: (72,75) A123 L130 K38) with an elongated lower lobe; the lobe pinches off (128-131k) into a
separate closed vesicle with 9-10 catalysts that came from the parent (134k: (64,66) A22 L59 K10; the
mother keeps K30-33). The daughter persists as its own cell at 135-143k (adhered to the mother in some
frames, so the two are sometimes one tail-contact aggregate).
Dense re-run of c06 (runs/lifeA_c06r, bitwise identical to c06 at 120k and 130k, snapshots every 200
steps 120k-136k): the c06 division is elongation -> neck -> the neck walls meet -> fission at ~131.5k,
leaving a short bilayer flap on one daughter (/tmp/claude-0/c06r.png, c06r2.png).
Common pattern: a LARGE cell (A >= 80-120, K >= 23-38) with excess membrane forms an elongated lobe that
pinches off. divs.py now also accepts daughters in one tail-contact aggregate if their lumens are > 3.5
apart (two bilayers; a shared wall is ~2-2.5) and reports both counts (screening only; every division
must be checked by eye).
x-batch (r0_tie 0.75 regime, partial): x1 (seed 2) and x2 (p_rep 1e-4) each give 1 "gap-confirmed" candidate,
but x1's (109k-115k, (49,43)) is by eye a big vesicle partitioned by an inner wall (compartments in one
membrane), NOT a division -> the gap criterion gives false positives; only eye checks count.
Official pipeline on u3 (tools/analyze.py): 1 'deling' found but invalid (one daughter has K0); criterion 2
'deels': only 224 of 903 syntheses happen inside detected lumens (most catalysts sit in open pockets);
criterion 6: cells WITHOUT catalysts gain more lipids (+415 per 100k steps) than cells with (-36): they
absorb ribbons. The excess lipid (ribbons from f_lip 0.20) is a root problem.
Next (direction A): self-made membranes - soup with LOW f_lip so that membranes come from synthesis
inside K-containing N droplets (no ribbons, only droplets with catalysts get a coat).

### Batch x (r0_tie 0.75, p_ld 1e-5, p_kd 1e-5, feed cap 0.13; from 100k; stopped at ~250k)
| run | change vs u3 | cells @125k..250k (every 25k) | strict divisions | gap-only candidates |
|---|---|---|---|---|
| x1 | seed 2 | 10 14 12 7 13 | 0 | 3 (x1@109-115k checked by eye: compartments, not a division) |
| x2 | p_rep 1e-4 | 13 14 3 1 2 | 0 | 1 |
| x3 | p_syn 3e-4 | 9 7 9 6 5 0 | 0 | 0 |
| x4 | p_feed 1e-4 | 16 8 7 9 3 7 | 0 | 0 |
Stopped early (unpromising). Decision: change the world, not the rates. Two redesign tests from SOUP:
A = self-made membranes (f_lip 0.04: almost all lipid must be synthesised by catalysts inside N droplets);
C = catalyst-coacervate lumen (K immiscible with water a_W_K 45, N binds K a_N_K 15, heads like K a_H_K 22;
N water-soluble a_W_N 25 and membrane-permeable a_T_N 60; W and K impermeable): lumen grows by
replication (N -> K), membrane by synthesis, and N can actually cross the bilayer.

### Redesign tests from SOUP (100k steps, snap 1000)
| run | design | result |
|---|---|---|
| a1 | A: f_lip 0.04, c_N 0.12, f_Ka 0.01, syn 3e-4, rep 5e-5, ld 1e-5, kd 1e-5, feed 1e-4 cap 0.12 | **membranes are made only where catalysts are**: 30k: ~15-20 N droplets with K, each with a self-made partial/complete bilayer coat; naked N droplets (no K) stay uncoated. 60k: separate closed vesicles. Lipids 300 -> 1310 by 100k: unchecked synthesis makes excess membrane -> networks + K clumps at 100k. 3 unconfirmed split candidates. |
| a2 | A + r0_tie 0.75 | same picture; big cells form INTERNAL septa (Ono-Ikegami-like compartments, 96-98k), not yet separate daughters |
| b1 | C: K-coacervate lumen (a_W_N 25, a_H_N 25, a_T_N 60, a_W_K 45, a_N_K 15, a_H_K 22), f_lip 0.10, rep 1e-3 | K runaway (300 -> 17357), K blobs |
| b2 | C with rep 3e-4 | K 300 -> 3357, dense green K blobs partly wrapped, many ribbons; not biological-looking |
Decision: continue with design A (self-made membranes). Next: control membrane amount with lipid
decay (p_ld) so that synthesis vs decay sets a steady membrane per cell.

### Batch m - self-made world (A) with lipid decay (from soup seed 11, 150k steps)
| run | rates | closed cells (detector) | divisions | look |
|---|---|---|---|---|
| m1 | syn 3e-4 rep 5e-5 ld 5e-5 | 0-3 | 0 | 8-10 big K-rich droplets, mostly partial coats, cells cluster |
| m2 | syn 5e-4 rep 5e-5 ld 1e-4 | 1-6 | 0 | |
| m3 | m1 + r0_tie 0.75 | 4-8 | 1 gap-candidate (132-133k) = by eye a merging/separating foam region, NOT a division | K clumps in deflated cells |
| m4 | m1 + rep 1e-4 | 0-7 | 0 | K 300 -> 923 |
Idea for an intrinsic cycle: with fast lipid turnover the coat of a cell opens when the lumen
outgrows it (open cell = fast N uptake by merging with nutrient droplets) and closes/deflates when
synthesis wins (closed cell = excess area = division). Test higher p_ld with higher p_syn.
### Batch n - self-made world, fast lipid turnover (soup seed 11, ~145k steps)
| run | rates | closed cells | divisions |
|---|---|---|---|
| n1 | syn 5e-4 rep 5e-5 ld 2e-4 kd 2e-5 feed 1e-4 | 0-4 | 0 |
| n2 | syn 1e-3 rep 1e-4 ld 2e-4 kd 5e-5 | 1-3 | 0 |
| n3 | syn 1e-3 rep 1e-4 ld 5e-4 kd 5e-5 | 0-1 | 0 |
| n4 | n1 + feed 3e-4 | 0-3 | 0 |
Lesson: with fast turnover the coats never close; the self-made world gives few closed cells.
Next: a_H_H 28-34 (head-head repulsion: no stacked multilayers, cheaper pore edges -> excess area must
show as shape change, and pores give both permeability and reconnection).

### Batch h05-h10 - head-head repulsion a_H_H (from 100k)
| run | change | cells @115/120/125k | N entries/perim/tau | divisions (closed mode) |
|---|---|---|---|---|
| h05 | a_H_H 28, feed 3e-4 | 8 6 8 | 5.3e-4 | |
| h06 | a_H_H 31, feed 3e-4 | 10 10 13 | 4.9e-4 | |
| h07 | a_H_H 34, feed 3e-4 | 8 7 4 | 4.0e-4 | |
| h08 | a_H_H 28 + r0_tie 0.75, feed 3e-4 | 15 12 13 (Nin up to 1979) | 4.7e-4 | |
| h09 | a_H_H 30, closed syn 5e-4 | 14 7 4 1 4 1 4 | | 0 |
| h10 | a_H_H 34, closed syn 5e-4 | 14 11 7 4 3 4 1 | | 0 |

### Survey of all runs with divs.py (candidate = parent's catalysts end up in 2 separate cells)
Candidates are most frequent with r0_tie 0.75-0.85 + feed (u2 5, u4 5, x1 9, x2 4 per 100-150k steps).
Eye check of g03 (140k-152k, (63,31)): a big cell (A82, K23) buds off a lobe with ~6 catalysts that
becomes its own closed vesicle (146-152k), the mother keeps K16-18. Same pattern as u3 and c06:
**the emergent reproduction mode in this world is BUDDING of large cells with excess membrane**
(unequal division: mother K16-38, daughter K6-10). Rate ~1 per 100k steps per box (~10 cells).

### CORRECTION (important) - u3 was NOT a division
divs.py now checks where each daughter's catalysts were 5/10/20 frames before the parent frame.
u3's "daughter" (64,66) K10 holds the catalysts of a SEPARATE small cell that had fused with the big
cell at ~118-125k and separated again at ~131k (fusion followed by re-separation, not reproduction).
Re-checked: c06 (both daughters' catalysts in one cell since >= 112k) and g03 (both in one cell at
118-120k) are genuine. g03 re-run deterministically with dense snapshots (runs/lifeA_g03r, bitwise
identical to g03 at 150k): 140-143k a big cell with an arm containing catalysts, 144-146k neck,
147-148k the arm is a separate vesicle touching the mother, 150-154k separate closed vesicle with
~6 catalysts below the mother (/tmp/claude-0/g03r.png). y1 candidates checked by eye: compartments
forming and merging inside long tubes (NOT divisions).
So far: 2 genuine divisions (c06 closed mode, g03 fed), both budding of a big cell; none repeated.

### y1 - the r0_tie 0.8 life laws from SOUP (seed 1, chem on from step 0, 150k steps)
Vesicles still form from the soup: 12-17 closed cells with catalysts at 20-60k steps (vs 10-14 for
membranes.ini without chemistry), then 6-13. Kb appears by mutation (b1..b6). No genuine division.

### y2 - long run from the checkpoint, r0_tie 0.8, syn 2e-4 (Kb 6e-4, mu 0.02), rep 5e-5, ld 1e-5, kd 1e-5, feed 3e-4 cap 0.13
cells every 20k (100k-320k): 14 12 13 15 17 11 10 4 3 5 3 3; lipids 1500 -> 2613, K 300 -> 663 (Kb 8);
largest aggregate grows to ~2000 lipids: the population peaks at ~170k and then collapses into a
membrane network ("foam"). Stopped at 332k. Cause: synthesis >> lipid decay (lipids accumulate).
Next: y3/y4 with turnover balanced for a steady state (p_ld 5e-5, p_kd 2.5e-5), from checkpoint and soup.
Tool: `scan/walls.py RUN STEP CELL_A CELL_B` counts tail layers along corridors between the two lumens
(1 = one shared bilayer wall, >= 2 = two separate membranes). g03r @153750 mother (61,34) K22 vs bud
(69,23) K4: 2-4 tail layers on every corridor, e.g. NNNHHTTTHHWHWHWHTTTTHHNKN (two bilayers with water
between) -> separate membranes, touching. c06 @127000 compartments: 1 tail layer (shared wall) at the
neck stage, as expected before the final separation at ~131.5k.

### y3 / y4 - balanced turnover (p_ld 5e-5, p_kd 2.5e-5), r0_tie 0.8, syn 2e-4 (Kb 6e-4, mu 0.02), rep 5e-5, feed 3e-4 cap 0.13
y3 (from the checkpoint): cells every 20k 14 13 10 8 7 10 11 13 10 (100k-260k); lipids stay ~1450 (no
runaway), largest aggregate 400-900 (no collapse into one network) -> the most stable living world so
far. 12 candidates / 3 loose-confirmed by 260k. Eye check of the 241k-261k event ((81,31), parent K32,
catalysts together in one cell at 236k): the cell splits into an upper (K12-17) and a lower (K16-18) cell
that both persist to >= 261k; walls.py: water + bilayer between the lumens (separate), but the
surroundings are a dense membrane maze, so this one is "probable", not clean.
y4 (same laws from SOUP, seed 1): 11-12 cells from 20k to 120k, then 6 at 160k; 1 loose candidate at
45k-60k (parent K26 -> K20 + K9, 4 frames in different aggregates) whose lower daughter ends in the
network after 62k (not clean).

### Official pipeline (tools/analyze.py) on the balanced-turnover runs
| run | 1 grens | 2 metabolisme | 3 groei | 4 voortplanting | 5 erfelijkheid+selectie | 6 dood |
|---|---|---|---|---|---|---|
| y3 (checkpoint, 100k-400k) | ja | ja (727/2139 syntheses in lumens; rho 0.69) | ja (track 379: 50->122 lipids, lumen 27.6->47.1) | deels (4 'delingen', all with a K-free daughter in a network) | nee | ja (7 cells) |
| y4 (soup, 0-300k) | ja | ja | ja (12 tracks) | deels (4 splits; the K-carrying ones are fusion products / shared aggregates) | deels (Kb share 1% -> 4%, tau 0.50) | ja (18 cells) |
So with r0_tie 0.8 and balanced turnover, criteria 1, 2, 3, 6 are met by the official tools;
reproduction (4) is the missing piece: no clean, repeated division.
Hypothesis for the stickiness: free N outside (feed cap 0.13 -> ~2500 N outside cells) wets the outer
head layers (a_H_N 22 << a_W_N 45) and glues vesicles into clusters, so buds stay attached and re-fuse.
Test lower caps next (v5/v6).
