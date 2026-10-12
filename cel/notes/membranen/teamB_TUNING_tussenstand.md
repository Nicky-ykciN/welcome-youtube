# memB — spontaneous membranes: tuning notes

Agent memB (strategy: lipid architecture + concentration). Private engine copy: this directory.
Runs: /home/user/welcome-youtube/cel/runs/memB_*. Start state is ALWAYS init=soup (SPEC §0).

## 0. Status / resume pointer (update after every batch)

- Session 2 (this file was rewritten after a machine restart; the first session's notes were lost).
- Engine copy builds (`make` gives a bitwise identical binary). Build/test: `make`; `tests/molforcetest`.
- Session 1 ran 124 runs (all chemistry OFF, L=64 except L01-L04 at L=100). Reconstructed below (§2, §3).
- NEXT: see §4 (plan) and §5 (session-2 log).

## 1. Engine changes made in this private copy (session 1, verified by diff against orig/oercel.c)

- Molecule template (`mol_build`): `lip_arch = linear | pi | y | bola`.
  - linear: lip_nH heads then lip_nT tails (identical to the original engine).
  - pi: two bonded heads H1-H2 (rest `r0_head`), each carrying a tail of lip_nT beads
    (phospholipid-like double-tailed lipid, 2 + 2 nT beads).
  - y: one head carrying two tails of lip_nT beads (1 + 2 nT beads).
  - bola: asymmetric membrane-spanning macrocycle: head pair on one face, single head on the
    other face, two tails (3 + 2 nT beads).
  - `k_head`, `cos_head`: angle term U = k_head (cos th - cos_head)^2 at the branch beads.
  - `lip_tie`: ladder rungs (bonds) between the two tails, first lip_tie tail-bead pairs.
  - `syn_nN`: synthesis consumes syn_nN N beads; remaining beads of the new lipid are recruited
    from the nearest W (0 = all beads from N, i.e. lipid length N consumed).
- Synthesis places the new lipid with the same template (lowest-overlap orientation +
  relaxation, as the original engine). Snapshot bonds list all template bonds (i<j).
- Checkpoint version 3 = version 2 + architecture code (linear lipids keep version 2).
- tests/molforcetest.c: bonded forces of every template vs finite differences of an
  independently written energy.
- MAXMLEN 8 -> 12.

## 2. Scan tooling (scan/)

- run.sh NAME INI [k=v...]: one 540 s chunk (restarts from ckpt.bin when present).
- batch.sh INI JOBFILE: 2 concurrent single-thread jobs from a job list (jobs1..28.txt).
- ringstat.py: tools/cells.detect on every snapshot; "isolated vesicle" = detected cell
  (tools criteria) whose aggregate has exactly this lumen, does not wrap the torus and
  holds >= 80% of the aggregate lipids. Tracks by centroid (< 6). Cache: RUN/memB_ringcache.json.
- summarize.py: Markdown table of all runs (parameters changed vs tune_base + ring stats).
- persist.py / stiffness.py: membrane persistence length / kappa estimates (noisy).
- metrics.py: per-snapshot detection time series.
- Base parameters: params/tune_base.ini (L=64, chem=0, f_lip=0.10, f_Ka=0.005, c_N=0.12,
  a_W_H=20, a_W_T=80, a_H_T=50, a_N_T=40, a_K_H=30, a_K_T=120, dt=0.03, warmup 1000).

## 3. What session 1 tried and learned (reconstructed from the 124 run directories)

Overall: NO configuration gave "several" closed vesicles. Best L=64 runs reached 1-2
isolated closed vesicles at a time (mean over snapshots <= 0.44), usually transient.
Full table: §6.

Series (L=64 unless noted, steps 60k-300k, chemistry off):
- s01-s04 linear H-T-T-T / H-T-T-T-T, f_lip 0.10-0.30: micelles + short worms, no vesicles.
- s05-s18 pi3 (2 heads, 2x3 tails), y3, ties, k_head, f 0.15-0.30: bilayer strips form
  (bilayers clearly favoured over micelles with double-tailed lipids), but no closed rings.
- s19-s30 pi2 / pi3 with a_W_T 60-120, a_H_T 35-70, k_angle 3-20, seeds: pi2 + a_W_T=100
  (s22) became the reference: long bilayer strips; one long-lived vesicle (21 snapshots) in
  300k steps; strips fuse into branched networks (Y/T junctions) that span the L=64 box.
- s31-s40 tied tails (lip_tie 1-3): NO networks (junctions rare), but strips are very stiff
  (kappa/kT ~ 70-170 from stiffness.py, noisy) with stable open ends, so they do not close.
  s38 (tie2, a_W_T=160) shows one closed stiff ring by eye at step 150k.
- s41-s64 pi2 with r0_head 0.6-0.9, a_W_H 15/25, a_N_T 60-100, c_N 0: r0_head 0.7-0.8 slightly
  better (mean iso 0.10-0.26); a_W_H=25 -> everything in one network; a_W_H=15 -> smaller
  aggregates; no breakthrough.
- b01-b08 bola (asymmetric spanning lipids): monolayer strips whose molecules alternate in
  orientation -> wedges pack flat, strips are wavy, no spontaneous curvature; bonds exceed 1.5
  (max 1.53-1.69) -> bola rejected.
- c01-c07, k01-k18: "consensus" pi2 + tie1 + k_head 20, or k_head 2-10 + k_angle 3-5, a_N_T 80-100:
  mean iso <= 0.14; k06 (k_head 5, k_angle 5) 300k steps: 3 short tracks. Linear H-T-T-T and
  H-H-T-T-T-T at k_angle 5 (k14, k15): no vesicles.
- p01-p10 pi1 (2 heads, 1 tail bead each: thinnest bilayer) with very high a_W_T 150-250:
  floppiest membranes (persistence length P ~ 5.6 from strip shapes, p02), most frequent loop
  formation (mean iso 0.2-0.31, p03 5 short tracks), but loops mostly form inside networks.
- t01-t06: catalyst/nutrient droplets (K-W 40-50, K-H 15; or N-W 35-40, N-H 15): no effect
  or worse.
- T01-T04: temperature cycles (amp 0.3-0.4, period 300-600) and kT 0.85: no improvement.
- S01-S04: Kolmogorov stirring: S01 (s22 + stir_A 2e-4) is the best run of session 1 (mean iso
  0.44, one vesicle tracked for 27 snapshots, always with K inside); stronger stirring 1e-3 destroys.
- L01-L04 (L=100, 100k-300k steps): at most 1 isolated vesicle at a time.

Physical picture (from looking at images, /tmp/memB/q_*.png in session 2):
- Double-tailed lipids reliably make bilayer strips within t ~ 300 (10k steps).
- Strips then grow by end-to-end and end-to-side fusion. End-to-side fusion makes T/Y
  junctions -> branched networks; at L=64 and f_lip=0.2 the network spans the box.
- Open strip ends are stable (low end-cap energy) so strips do not need to close.
- Ring closure needs strip length l > pi^2 kappa / Lambda_end and the ends to meet before the
  strip fuses with another strip. Stiff membranes (tie) suppress junctions but never close;
  floppy membranes (pi1) close often but mostly into network loops.

## 4. Plan (session 2)

1. Measure, per architecture, the three quantities that decide ring vs strip vs network:
   bending stiffness kappa, end-cap energy (how often ends exist / survive), and junction
   frequency, instead of only counting rings.
2. Directions not yet tried by session 1:
   - L >= 100 at LOWER lipid fraction (5-12%) with floppy thin bilayers: fewer collisions
     between strips, so a strip can close before it joins a network.
   - Heads bigger than tails in a way that destabilises junctions (monolayer spontaneous
     curvature c_m > 0) while high a_W_T keeps end caps costly.
   - Longer bonds in the head region / H-H-T-T-T-T style linear lipids with high a_W_T.
3. Then measure N permeation and K crossings for the best candidate; write membranes.ini.

## 5. Session-2 log

(entries appended below, newest last)

### Batch A-D (session 2), L=100, f_Ka=0.005, c_N=0.12, chem=0, 100k steps (t=3000), snap 5000, 1 thread x 2 jobs
Base: params/tune100.ini. "iso" = ringstat isolated closed vesicles (tools criteria, lumen >= 16).
"topo" = scan/topo.py (Reeb skeleton of tail centroids: ends, junctions, loops).

| run | lipid / changes | iso mean (2nd half) / max | topo 2nd half: ends / junctions | notes |
|---|---|---|---|---|
| A01 | pi1 tie1, a_W_T 200, a_T_N 120, f_lip 0.12 | 0.14 (0.18) / 1 | 65 / 1.5 | many short separate strips |
| A02 | same, f_lip 0.07 | 0 / 0 | - | short strips |
| A03 | pi1 tie1, a_W_T 300, a_T_N 150, f 0.10 | 0.05 / 1 | 39 / 1.0 | tiny closed rings (lumen r~2, area 12-24, 1 K inside) persist; most below lumen threshold 16 |
| A04 | pi1 k_head 5, a_W_T 200, f 0.10 | 0.14 (0.27) / 1 | 34 / 1.8 | |
| B01 | pi1 tie1, a_W_T 400, a_T_N 200 | 0 / 0 | | longer strips, no rings |
| B02 | pi1 tie1, a_W_T 300, f 0.14 | 0 / 0 | 43 / 1.9 | |
| B03 | pi1 tie1, a_W_T 300, a_H_T 100 | 0 / 0 | | many short strips (heads repel tails) |
| B04 | pi1 k_head 5, a_W_T 300 | 0.05 / 1 | 31 / 3.1 | some Y junctions |
| D01 | pi1 tie1, a_W_T 300, r0_head 0.7 | 0.62 (1.18) / 3 | 40 / 2.2 | BEST so far: thin floppy strips, several closed rings by eye (lumen up to 37) |
| D03 | pi2 tie2, a_W_T 300 | 0 / 0 | 36 / 2.5 | stiff strips |
| D04 | pi2 tie1, a_W_T 300 | 0 / 0 | 25 / 1.1 | stiff strips |
| D05 | = A03, seed 2 | 0.33 (0.55) / 2 | 42 / 1.5 | small rings |

Learned: (1) ties (rungs) suppress Y/T junctions -> no networks, rings are not re-absorbed;
(2) in S01 (session 1) the one long-lived ring was later absorbed into the network through
T-junctions, so junction suppression is required; (3) thin (pi1) tied lipids with very high
a_W_T make floppy strips that close; (4) wider head pair (r0_head 0.7) improved closure (D01).
Max bond: 1.44 in D01 occurs only during the warm-up ramp (step <= 1000); afterwards <= 1.22.

### Batch E, extensions, G, H (session 2), L=100, chem 0, warmup 3000 unless noted
"cells" = all tools-detected closed lumens per snapshot (tools/cells.detect criteria); "iso" as above.

| run | lipid / changes (all pi1 tie1, a_T_N 150, f_lip 0.10 unless noted) | iso mean (2nd half) / max | cells 2nd half | topo ends / junc | notes |
|---|---|---|---|---|---|
| E01 | a_W_T 300, r0_head 0.8 | 0.38 (0.73) / 2 | ~1.2 | 33 / 4.0 | |
| E02 | a_W_T 300, r0_head 0.9 | 0.57 (1.09) / 2 | ~1.5 | 40 / 2.4 | maxbond 1.45 after warm-up (r0_head 0.9 bond) |
| E03 | a_W_T 300, r0_head 0.7, f_lip 0.14 | 0.38 (0.73) / 2 | ~1.3 | 40 / 4.2 | |
| E04 | a_W_T 200 (a_T_N 120), r0_head 0.7 | 0.05 / 1 | ~0.1 | 50 / 1.0 | a_W_T 200 much worse than 300 |
| E02 to 300k | | 0.30 (0.10) / 2 | ~0.3 | 33 / 4.3 | rings form at t~1500-3000 then disappear: coarsening, NOT accumulation |
| D01 to 300k | | 0.44 (0.23) / 3 | ~0.6 | 29 / 1.9 | same; ends ~30 (15 strips) steady from t~3000 on |
| E02x (fine snaps, 100k-120k from E02) | | | | | rings form through LASSOS: strip end attaches to its own side (T-junction), junction later releases the tail -> isolated ring; the reverse (strip attaches to ring, ring re-opens) also happens. Rings live ~5-15k steps. |
| G01 | r0_head 0.7, k_head 10 | 0.28 (0.54) / 2 | | 31 / 1.8 | |
| G02 | r0_head 0.7, k_head 30 | 0.16 (0.31) / 1 | | 31 / 1.5 | |
| G03 | r0_head 0.6 | 0.12 (0.15) / 1 | | 36 / 1.0 | |
| G04 | r0_head 0.7, a_W_H 25 | 1.00 (1.38) / 3 | ~2 | 23 / 16 | crumpled membranes, more junctions; best single run so far |
| H01 | r0_head 0.7, a_W_H 30 | 0 | 0 | 12 / 68 | lipids collapse into dense blobs (heads not hydrophilic enough) |
| H02 | = G04, seed 2 | 0.04 (0.08) / 1 | ~0.5 | 24 / 14 | seed variance is LARGE: G04's result was partly luck |
| H03 | r0_head 0.9, a_W_H 25 | 0.64 (1.00) / 2 | ~2.5 | 28 / 31 | |
| H04 | r0_head 0.7, a_W_H 25, a_W_T 400 | 0 | ~0.2 | 18 / 26 | |

Learned: thin tied pi1 lipids + a_W_T 300 + wide head pair (r0_head 0.7-0.9) give ~1 closed
vesicle at a time at L=100 (best of everything so far, but far from "several"); rings are formed
and destroyed dynamically (junction-mediated), the count does not grow with time; a_W_H 25 is
near a collapse boundary (30 = blobs). Seed-to-seed variance is large, so single runs mislead.

### Batches I-N (session 2), L=100, chem 0; all pi1 tie1 a_W_T 300 a_T_N 150 f_lip 0.10 unless noted

| run | changes | iso mean (2nd half) / max | cells (2nd half, approx) | topo ends / junc (2nd half) | notes |
|---|---|---|---|---|---|
| I01 | r0_head 0.7, f_lip 0.06, 200k | 0.02 / 1 | ~0 | 30 / 0.9 | dilution does not help |
| I02 | r0_head 0.9, f_lip 0.06, 200k | 0.02 / 1 | ~0.3 | 28 / 2.0 | |
| B01 to 400k | r0_head 0.5, a_W_T 400 | 0.02 / 1 | ~0.1 | 24 / 1.4 | ends plateau at ~20: strips also break (end cost moderate) |
| A03 to 400k | r0_head 0.5 | 0.30 (0.39) / 2 | ~0.4 | 33 / 1.5 | small rings come and go; no accumulation |
| J01 | r0_head 0.5, a_H_H 15 | 0 | 0 | 18 / 28 | cohesive heads -> junction networks |
| J02 | r0_head 0.7, a_H_H 15 | 0 | 0 | 12 / 51 | networks |
| J03 | r0_head 0.5, a_H_T 35 | 0.10 (0.18) / 1 | | 38 / 9 | |
| J04 | r0_head 0.7, a_H_H 35 | 0 | 0 | 68 / 0 | repulsive heads -> many short strips (cheap end caps), no junctions |
| K01 | r0_head 0.7, a_H_H 18 | 0.52 (0.73) / 2 | ~2.5 | 21 / 10 | |
| K02 | r0_head 0.7, a_H_H 20 | 0.19 (0.36) / 2 | ~0.5 | 28 / 6 | two big rings (area 198, 131) at the end |
| K03 | r0_head 0.7, a_H_H 22 | 0.10 (0.18) / 1 | ~0.5 | 27 / 4 | |
| K04 | r0_head 0.5, a_H_H 20 | 0.19 (0.36) / 1 | ~0.4 | 31 / 3 | |
| D03 to 400k | pi2 tie2 | 0 | 0 | 8 / 3 | IRREVERSIBLE end-to-end fusion (ends 60 -> 8), stiff strips merge into 1-2 box-size aggregates, never close |
| D04 to 400k | pi2 tie1 | 0 | ~1 (network loop) | 4 / 5 | same: 466/500 lipids in one aggregate |
| M01 | D01 + stir_A 1e-4 | 0 | ~0 | 34 / 1.2 | stirring does not help |
| M02 | D01 + stir_A 3e-4 | 0.05 / 1 | ~0.1 | 33 / 2.3 | |
| M03 | K01 + stir_A 2e-4 | 0 | ~0.4 | 19 / 11 | |
| M04 | D01 + kT_amp 0.2, period 200 | 0.05 / 1 | ~0 | 44 / 2 | temperature cycle does not help |
| N01 | D01 + a_H_N 15, a_T_N 60 | 0 | 0 | 60 / 0.7 | N caps membrane ends -> many short strips |
| N02 | N01 + a_W_N 30 | 0 | 0 | 74 / 0.6 | |
| N03 | D01 + a_H_N 20, a_T_N 40 | 0 | 0 | 71 / 0.8 | |
| N04 | D01 + a_T_N 60 | 0.05 / 1 | ~0.1 | 51 / 1.7 | a_T_N must stay high: N that tolerates tails is an edge-active agent |

Learned: a_H_H is a clean knob for the end/junction balance (monolayer spontaneous curvature):
15 -> networks, 35 -> short open strips; 18-25 in between. The pi1-tie family saturates at
~1-3 closed vesicles at a time at L=100 (dynamic ring-chain equilibrium). Stiffer membranes
(pi2 tie) are in an irreversible regime but stiff strips never self-close (they span the box).
Stirring/temperature cycles do not help. N with a_T_N <= 60 lowers the end energy (bad).

## 6. Appendix: all session-1 runs (generated by scan/summarize.py from memB_ringcache.json)

"iso. vesicles" = isolated closed vesicles per snapshot (see §2). "all cells" = every
detected lumen including loops inside networks. "largest aggregate" = lipids in the largest
aggregate / all lipids, last snapshot.

| run | changed parameters (vs. tune_base: L=64, H-T-T-T, k_angle=10, a_WT=80, a_NT=40, a_WH=20, f_Ka=0.005) | steps | iso. vesicles: max / mean / tracks>=2 snaps (lifetimes) | all cells (last) | vesicles with K | largest aggregate (last) |
|---|---|---|---|---|---|---|
| L01_pi2_rh05_f20 | L=100 f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 f_Ka=0.01 | 100000 (snap 2000) | 1 / 0.06 / 1 [3] | 4 | 3/3 | 779/1000 |
| L02_pi2_rh06_f20 | L=100 f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.6 a_W_T=100 f_Ka=0.01 | 100000 (snap 2000) | 1 / 0.12 / 1 [4] | 3 | 4/6 | 385/1000 |
| L03_cons_ka5_f15 | L=100 f_lip=0.15 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 k_angle=5 a_W_T=100 a_T_N=80 f_Ka=0.01 | 300000 (snap 5000) | 0 / 0.00 / 0  | 0 | 0/0 | 227/750 |
| L04_kh5_ka5_f15 | L=100 f_lip=0.15 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 f_Ka=0.01 | 300000 (snap 5000) | 1 / 0.02 / 0  | 2 | 1/1 | 696/750 |
| S01_s22_stir2e-4 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 stir_A=0.0002 | 120000 (snap 2000) | 1 / 0.44 / 1 [27] | 3 | 27/27 | 408/410 |
| S02_s22_stir1e-3 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 stir_A=0.001 | 120000 (snap 2000) | 0 / 0.00 / 0  | 2 | 0/0 | 297/410 |
| S03_k06_stir5e-4 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 stir_A=0.0005 | 120000 (snap 2000) | 0 / 0.00 / 0  | 3 | 0/0 | 390/410 |
| S04_cons_stir5e-4 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=100 a_T_N=80 stir_A=0.0005 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 176/410 |
| T01_s47_kTcyc03 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 kT_amp=0.3 kT_period=600 | 150000 (snap 2000) | 2 / 0.08 / 1 [3] | 0 | 0/6 | 145/410 |
| T02_k06_kTcyc03 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 kT_amp=0.3 kT_period=600 | 150000 (snap 2000) | 1 / 0.04 / 1 [3] | 0 | 3/3 | 322/410 |
| T03_s47_kT085 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 | 150000 (snap 2000) | 1 / 0.01 / 0  | 0 | 1/1 | 372/410 |
| T04_s47_kTcyc04_P300 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 kT_amp=0.4 kT_period=300 | 150000 (snap 2000) | 1 / 0.03 / 0  | 0 | 1/2 | 133/410 |
| b01_bola3_rh07_f15 | f_lip=0.15 lip_arch=bola r0_head=0.7 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 58/205 |
| b02_bola3_rh09_f15 | f_lip=0.15 lip_arch=bola r0_head=0.9 | 90000 (snap 2000) | 1 / 0.13 / 1 [3] | 0 | 0/6 | 69/205 |
| b03_bola4_rh08_f15 | f_lip=0.15 lip_arch=bola lip_nT=4 r0_head=0.8 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 61/168 |
| b04_bola3_rh07_f20_wt100 | f_lip=0.2 lip_arch=bola r0_head=0.7 a_W_T=100 | 90000 (snap 2000) | 1 / 0.02 / 0  | 1 | 1/1 | 197/273 |
| b05_bola3_rh09_hh15 | f_lip=0.15 lip_arch=bola r0_head=0.9 a_H_H=15 | 90000 (snap 2000) | 1 / 0.20 / 1 [9] | 0 | 1/9 | 52/205 |
| b06_bola3_rh09_hh18 | f_lip=0.15 lip_arch=bola r0_head=0.9 a_H_H=18 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 82/205 |
| b07_bola3_rh11_hh15 | f_lip=0.15 lip_arch=bola r0_head=1.1 a_H_H=15 | 50000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 46/205 |
| b08_bola3_rh09_hh15_wt100 | f_lip=0.15 lip_arch=bola r0_head=0.9 a_W_T=100 a_T_N=80 a_H_H=15 | 50000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 50/205 |
| c01_wt100_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 253/410 |
| c02_wt130_nt40 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=130 | 120000 (snap 2000) | 1 / 0.03 / 0  | 0 | 2/2 | 174/410 |
| c03_wt130_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=130 a_T_N=80 | 120000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 236/410 |
| c04_wt100_nt80_ka3 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 k_angle=3 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 1 / 0.11 / 2 [2, 5] | 1 | 1/7 | 142/410 |
| c05_notie_kh20_wt100_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=20 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 378/410 |
| c06_wt100_nt80_f15 | f_lip=0.15 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 171/307 |
| c07_wt130_nt100_long | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=130 a_T_N=100 | 300000 (snap 5000) | 1 / 0.03 / 0  | 0 | 0/2 | 410/410 |
| k01_kh2_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=2 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 251/410 |
| k02_kh5_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 283/410 |
| k03_kh10_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=10 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 302/410 |
| k04_kh5_nt40 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 a_W_T=100 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 142/410 |
| k05_kh5_nt80_rh06 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 r0_head=0.6 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 382/410 |
| k06_kh5_nt80_ka5 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 | 300000 (snap 2000) | 1 / 0.14 / 3 [6, 4, 3] | 1 | 13/14 | 410/410 |
| k07_kh5_ka5_s2 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 seed=2 | 120000 (snap 2000) | 1 / 0.13 / 2 [2, 4] | 2 | 8/8 | 204/410 |
| k08_kh5_ka3 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=3 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 1 / 0.03 / 1 [2] | 0 | 2/2 | 243/410 |
| k09_kh8_ka5 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=8 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 1 / 0.05 / 1 [2] | 1 | 2/3 | 276/410 |
| k10_kh5_ka5_nt100 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=100 | 120000 (snap 2000) | 1 / 0.11 / 1 [7] | 0 | 0/7 | 350/410 |
| k11_kh5_ka5_f15 | f_lip=0.15 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 191/307 |
| k12_kh3_ka5 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=3 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 410/410 |
| k13_pi3_kh5_ka5 | f_lip=0.2 lip_arch=pi k_head=5 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 307/307 |
| k14_ht3_ka5 | f_lip=0.2 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 543/614 |
| k15_h2t4_ka5 | f_lip=0.2 lip_nH=2 lip_nT=4 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 59/410 |
| k16_kh5_ka5_f25 | f_lip=0.25 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 424/512 |
| k17_kh5_ka5_wt120 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=120 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 393/410 |
| k18_kh5_ka5_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 a_W_H=15 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 142/410 |
| p01_pi1_wt150 | f_lip=0.2 lip_arch=pi lip_nT=1 a_W_T=150 a_T_N=100 | 120000 (snap 2000) | 1 / 0.23 / 3 [6, 2, 4] | 2 | 14/14 | 414/614 |
| p02_pi1_wt200 | f_lip=0.2 lip_arch=pi lip_nT=1 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 2 / 0.31 / 1 [10] | 1 | 15/19 | 266/614 |
| p03_pi1_wt200_kh5 | f_lip=0.2 lip_arch=pi lip_nT=1 k_head=5 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 2 / 0.28 / 5 [2, 2, 4, 4, 3] | 1 | 8/17 | 218/614 |
| p04_pi2_ka0_kh5 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=0 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 0 / 0.00 / 0  | 2 | 0/0 | 410/410 |
| p05_pi1_wt200_kh10 | f_lip=0.2 lip_arch=pi lip_nT=1 k_head=10 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 1 / 0.21 / 2 [6, 5] | 0 | 8/13 | 156/614 |
| p06_pi1_wt200_tie | f_lip=0.2 lip_arch=pi lip_nT=1 lip_tie=1 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 1 / 0.03 / 0  | 1 | 2/2 | 86/614 |
| p07_pi1_wt250_kh5 | f_lip=0.2 lip_arch=pi lip_nT=1 k_head=5 a_W_T=250 a_T_N=150 | 120000 (snap 2000) | 1 / 0.25 / 3 [6, 2, 2] | 0 | 9/15 | 338/614 |
| p08_pi1_wt200_kh5_f15 | f_lip=0.15 lip_arch=pi lip_nT=1 k_head=5 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 182/461 |
| p09_pi1_wt200_kh5_rh06 | f_lip=0.2 lip_arch=pi lip_nT=1 k_head=5 r0_head=0.6 a_W_T=200 a_T_N=120 | 120000 (snap 2000) | 2 / 0.16 / 1 [3] | 0 | 4/10 | 125/614 |
| p10_pi1_wt200_kh5_wh15 | f_lip=0.2 lip_arch=pi lip_nT=1 k_head=5 a_W_T=200 a_T_N=120 a_W_H=15 | 120000 (snap 2000) | 1 / 0.05 / 0  | 0 | 2/3 | 90/614 |
| s01_ht3 |  | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 78/307 |
| s02_ht4 | lip_nT=4 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 67/246 |
| s03_ht3_f20 | f_lip=0.2 | 60000 (snap 2000) | 1 / 0.03 / 0  | 1 | 0/1 | 125/614 |
| s04_ht3_f30 | f_lip=0.3 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 338/922 |
| s05_pi3_f15 | f_lip=0.15 lip_arch=pi | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 66/230 |
| s06_pi3tie_f15 | f_lip=0.15 lip_arch=pi lip_tie=1 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 62/230 |
| s07_y3_f15 | f_lip=0.15 lip_arch=y | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 126/263 |
| s08_pi3kh_f15 | f_lip=0.15 lip_arch=pi k_head=20 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 77/230 |
| s09_pi2_f15 | f_lip=0.15 lip_arch=pi lip_nT=2 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 108/307 |
| s10_pi3ka3_f15 | f_lip=0.15 lip_arch=pi k_angle=3 | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 100/230 |
| s11_pi3_f25 | f_lip=0.25 lip_arch=pi | 60000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 197/384 |
| s12_y3_f25 | f_lip=0.25 lip_arch=y | 60000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 235/439 |
| s13_pi3_f25s2 | f_lip=0.25 lip_arch=pi seed=2 | 90000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 365/384 |
| s14_pi3tie_f25 | f_lip=0.25 lip_arch=pi lip_tie=1 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 158/384 |
| s15_pi3kh_f25 | f_lip=0.25 lip_arch=pi k_head=20 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 196/384 |
| s16_pi3_f30 | f_lip=0.3 lip_arch=pi | 90000 (snap 2000) | 0 / 0.00 / 0  | 2 | 0/0 | 461/461 |
| s17_pi3_f20 | f_lip=0.2 lip_arch=pi | 90000 (snap 2000) | 1 / 0.04 / 0  | 1 | 0/2 | 125/307 |
| s18_pi3_f25_wh25 | f_lip=0.25 lip_arch=pi a_W_H=25 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 384/384 |
| s19_pi3_f20_wt100 | f_lip=0.2 lip_arch=pi a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 174/307 |
| s20_pi3_f20_wt60 | f_lip=0.2 lip_arch=pi a_W_T=60 | 90000 (snap 2000) | 1 / 0.09 / 1 [4] | 0 | 4/4 | 127/307 |
| s21_pi3_f20_ka20 | f_lip=0.2 lip_arch=pi k_angle=20 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 189/307 |
| s22_pi2_f20_wt100 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 | 300000 (snap 2000) | 1 / 0.27 / 1 [21] | 0 | 19/22 | 405/410 |
| s23_pi3_f20_rh08 | f_lip=0.2 lip_arch=pi r0_head=0.8 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 123/307 |
| s24_pi3_f20_ht35 | f_lip=0.2 lip_arch=pi a_H_T=35 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 236/307 |
| s25_pi2_f20_wt120 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=120 | 90000 (snap 2000) | 1 / 0.26 / 2 [3, 9] | 2 | 0/12 | 410/410 |
| s26_pi2_f15_wt100 | f_lip=0.15 lip_arch=pi lip_nT=2 a_W_T=100 | 90000 (snap 2000) | 1 / 0.07 / 0  | 2 | 1/3 | 244/307 |
| s27_pi2_f25_wt100 | f_lip=0.25 lip_arch=pi lip_nT=2 a_W_T=100 | 90000 (snap 2000) | 1 / 0.02 / 0  | 2 | 0/1 | 499/512 |
| s28_pi2_f20_wt100_ka3 | f_lip=0.2 lip_arch=pi lip_nT=2 k_angle=3 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 389/410 |
| s29_pi2_f20_wt100_s2 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 seed=2 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 401/410 |
| s30_pi2_f20_wt100_ht70 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_H_T=70 | 90000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 266/410 |
| s31_pi2t1_f20_wt100 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 109/410 |
| s32_pi2t2_f20_wt100 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=2 a_W_T=100 | 300000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 118/410 |
| s33_pi2t1kh_f20_wt100 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=100 | 90000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 79/410 |
| s34_pi2t2_f20 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=2 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 62/410 |
| s35_pi3t3_f20_wt100 | f_lip=0.2 lip_arch=pi lip_tie=3 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 74/307 |
| s36_pi2t2_f15_wt100 | f_lip=0.15 lip_arch=pi lip_nT=2 lip_tie=2 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 54/307 |
| s37_pi2t2_f20_wt130 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=2 a_W_T=130 | 150000 (snap 5000) | 0 / 0.00 / 0  | 0 | 0/0 | 158/410 |
| s38_pi2t2_f20_wt160 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=2 a_W_T=160 | 150000 (snap 5000) | 0 / 0.00 / 0  | 0 | 0/0 | 186/410 |
| s39_pi2t2_f30_wt130 | f_lip=0.3 lip_arch=pi lip_nT=2 lip_tie=2 a_W_T=130 | 150000 (snap 5000) | 1 / 0.19 / 1 [2] | 1 | 5/6 | 218/614 |
| s40_pi2t1_f20_wt130 | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 a_W_T=130 | 150000 (snap 5000) | 1 / 0.26 / 2 [6, 2] | 0 | 8/8 | 192/410 |
| s41_pi2_f20_wt100_nt60 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_T_N=60 | 90000 (snap 2000) | 1 / 0.02 / 0  | 1 | 1/1 | 410/410 |
| s42_pi2_f20_wt100_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_W_H=15 | 90000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 152/410 |
| s43_pi2_f20_wt100_wh25 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_W_H=25 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 410/410 |
| s44_pi2_f15_wt100_nt60 | f_lip=0.15 lip_arch=pi lip_nT=2 a_W_T=100 a_T_N=60 | 90000 (snap 2000) | 1 / 0.02 / 0  | 0 | 0/1 | 292/307 |
| s45_pi2_f20_wt100_s3 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 seed=3 | 90000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 365/410 |
| s46_pi2_f20_wt100_ka20 | f_lip=0.2 lip_arch=pi lip_nT=2 k_angle=20 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 2 | 0/0 | 410/410 |
| s47_pi2_f20_wt100_rh07 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 | 200000 (snap 2000) | 1 / 0.10 / 2 [8, 2] | 0 | 10/10 | 218/410 |
| s48_pi2_f20_wt100_rh09 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.9 a_W_T=100 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 60/410 |
| s49_pi2_f20_wt120_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=120 a_W_H=15 | 90000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 400/410 |
| s50_pi2_f20_wt120_rh07 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=120 | 90000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 143/410 |
| s52_pi2_f15_wt100_rh07 | f_lip=0.15 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 | 120000 (snap 2000) | 1 / 0.11 / 2 [2, 5] | 1 | 5/7 | 82/307 |
| s53_pi2_f25_wt100_rh07 | f_lip=0.25 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 | 120000 (snap 2000) | 1 / 0.26 / 1 [9] | 2 | 13/16 | 330/512 |
| s54_pi2_f20_wt100_rh07_s2 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 seed=2 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 221/410 |
| s55_pi2_f20_wt100_rh06 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.6 a_W_T=100 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 146/410 |
| s56_pi2_f20_wt100_rh08 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.8 a_W_T=100 | 120000 (snap 2000) | 1 / 0.15 / 4 [2, 3, 2, 2] | 0 | 4/9 | 140/410 |
| s57_pi2_wt120_rh07_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=120 a_W_H=15 | 120000 (snap 2000) | 1 / 0.07 / 0  | 0 | 2/4 | 104/410 |
| s58_pi2_wt120_rh08_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.8 a_W_T=120 a_W_H=15 | 120000 (snap 2000) | 1 / 0.07 / 1 [4] | 1 | 0/4 | 154/410 |
| s59_pi2_wt150_rh07_wh15 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=150 a_W_H=15 | 120000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 186/410 |
| s60_pi2_wt150_rh08_wh20 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.8 a_W_T=150 | 120000 (snap 2000) | 1 / 0.15 / 2 [2, 6] | 0 | 9/9 | 88/410 |
| s61_pi2_rh07_wt100_nt100 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 a_T_N=100 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 410/410 |
| s62_pi2_rh07_wt100_cN0 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.7 a_W_T=100 c_N=0 | 120000 (snap 2000) | 1 / 0.13 / 2 [2, 2] | 1 | 1/8 | 194/410 |
| s63_pi2_rh08_wt100_nt80 | f_lip=0.2 lip_arch=pi lip_nT=2 r0_head=0.8 a_W_T=100 a_T_N=80 | 120000 (snap 2000) | 2 / 0.18 / 3 [3, 2, 5] | 0 | 0/11 | 143/410 |
| s64_pi3_rh07_wt100_nt100 | f_lip=0.2 lip_arch=pi r0_head=0.7 a_W_T=100 a_T_N=100 | 120000 (snap 2000) | 1 / 0.02 / 0  | 1 | 1/1 | 307/307 |
| t01_Kdrop_kw40_kh15 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 a_W_Ka=40 a_H_Ka=15 a_N_Ka=30 f_Ka=0.01 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 410/410 |
| t02_Kdrop_kw40_kh25 | f_lip=0.2 lip_arch=pi lip_nT=2 k_head=5 k_angle=5 a_W_T=100 a_T_N=80 a_W_Ka=40 a_H_Ka=25 a_N_Ka=30 f_Ka=0.01 | 120000 (snap 2000) | 0 / 0.00 / 0  | 0 | 0/0 | 402/410 |
| t03_Ndrop_wn40_hn15 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_T_N=60 a_N_Ka=15 a_W_N=40 a_H_N=15 f_Ka=0.01 | 120000 (snap 2000) | 1 / 0.10 / 2 [2, 2] | 0 | 6/6 | 410/410 |
| t04_Ndrop_cons | f_lip=0.2 lip_arch=pi lip_nT=2 lip_tie=1 k_head=20 a_W_T=100 a_T_N=60 a_N_Ka=15 a_W_N=40 a_H_N=15 f_Ka=0.01 | 120000 (snap 2000) | 1 / 0.02 / 0  | 0 | 1/1 | 97/410 |
| t05_Kdrop_kw50_kh15 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_T_N=80 a_W_Ka=50 a_H_Ka=15 f_Ka=0.01 | 120000 (snap 2000) | 0 / 0.00 / 0  | 1 | 0/0 | 293/410 |
| t06_Ndrop_wn35_hn15 | f_lip=0.2 lip_arch=pi lip_nT=2 a_W_T=100 a_T_N=60 a_N_Ka=15 a_W_N=35 a_H_N=15 f_Ka=0.01 | 120000 (snap 2000) | 1 / 0.03 / 0  | 0 | 2/2 | 406/410 |
