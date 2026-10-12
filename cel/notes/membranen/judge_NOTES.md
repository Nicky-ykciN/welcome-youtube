# Jury membraanteams A en B — logboek

> **Wat is dit?** Het logboek van de jury die membraanteam A (memA) en B (memB) op bewijs vergeleek,
> team B koos, diens engine-wijziging (lipidesjablonen) in `cel/engine/oercel.c` inbouwde en
> `cel/engine/params/membranes.ini` schreef. Beschrijft ook hoe `runs/membranes_final` ontstond: het
> vertrekpunt (checkpoint op stap 100 000) van de levensteams. Momentopname uit de cloudsessie van
> 12 okt 2026, gekopieerd uit `cel/runs/judge_src/NOTES.md` (niet in git). `judge_src/...` en
> `binA`/`binB` zijn de privémap en -binaries van de jury op de ontwikkelmachine.
> Paden als `runs/...` zijn relatief aan `cel/` en wijzen naar run-uitvoer op de ontwikkelmachine
> (die map staat niet in git en bestaat niet op de werkplek-pc). Figuren die hier als bewijs worden
> genoemd en kleiner zijn dan ~2 MB zijn meegekopieerd naar `figs/` naast dit bestand (de verwijzingen
> hieronder zijn daarop aangepast); grotere figuren en losse kijkplaatjes niet.

---

# Judge: memA vs memB spontaneous membranes (notes, crash-safe log)

Task: judge Team A (memA, linear H-T-T-T, params runs/memA_src/params/membranes.ini, engine
unchanged) and Team B (memB, tied H2T2 "pi1-tie" lipid, runs/memB_src/params/membranes.ini, needs
memB engine copy) on evidence; pick winner or merge; port engine changes to cel/engine; rebuild;
validate; write engine/params/membranes.ini; produce a soup-run checkpoint in a vesicle-rich state.

Private dir: runs/judge_src (this file, scripts, binaries). Runs: runs/judge_*.

## 0. Status / resume pointer (update after every batch)

- [done] binaries: judge_src/binA/oercel (= engine/oercel.c, md5 a14b5bff... identical to
  engine/oercel and memA_src/oercel), judge_src/binB/oercel (= memB_src/oercel.c, md5 524f1f3c...
  identical to memB_src/oercel). Both rebuild bitwise identical.
- DONE (04:24). Winner B. Engine ported + installed, validate.sh 32/32 PASS (validate_final.log),
  engine/params/membranes.ini written, final soup run runs/membranes_final (membranes.ini as-is,
  final engine, step 100000, ckpt.bin = starting point; bitwise identical to memB_F01; 14 cells
  detected, 13.4 mean over 50-100k, all with catalysts). README updated (old copy:
  README_engine_before.md). Details in sections 2-5 below.

## 1. Plan

Batch 1 (formation, chem 0, L=100, 100k steps, seeds 7 and 8 = seeds neither team used,
snap_every 2000, stats_every 500, same detector for all):
- A  = memA membranes.ini as-is (binA)
- B  = memB membranes.ini as-is (binB)
- C  = control: linear H-T-T-T with B's repulsions (a_W_T 200, a_T_N 120, a_T_K 200, warmup 3000),
       binA. Tests whether B's gain is the lipid or the stronger tail repulsions.
- D  = control: pi1-tie lipid with A's repulsions (a_W_T 80, a_N_T 65, a_K_T 120, warmup 1000),
       binB.
Batch 2: crossings (dense snapshots 100k->130k every 100 steps, cross2.py), long-run stability
(continue to 200k), speed (ms/step benchmark same conditions), chemistry-on stress test (same slow
rates for both, 20k steps from 100k: max bond, vesicle survival), images (micro + goodsell).

## 2. Log
### Batch 1 (done 03:35): formation, chem 0, L=100, 100k steps, seeds 7/8, 1 thread x 4 jobs
Detector: tools/cells.detect defaults (jcells.py, cache RUN/judge_cells.json); 51 snapshots each.
mean2 = mean cells per snapshot over steps > 50k; fK = fraction of those cells with >= 1 K;
iso = cells whose membrane aggregate encloses only that lumen; Kin = share of all K inside cells.

| run | mean2 | max | last | withK | fK | iso | first>=3 | area med | K/cell | Kin |
|---|---|---|---|---|---|---|---|---|---|---|
| A_s7 (memA as-is) | 4.28 | 7 | 7 | 4.28 | 1.00 | 2.52 | 32k | 96 | 29 | 0.42 |
| A_s8 | 6.56 | 8 | 7 | 6.56 | 1.00 | 4.12 | 36k | 89 | 28 | 0.61 |
| B_s7 (memB as-is) | 9.68 | 17 | 11 | 9.36 | 0.97 | 6.76 | 14k | 39 | 13 | 0.47 |
| B_s8 | 11.28 | 16 | 11 | 10.84 | 0.96 | 7.40 | 10k | 38 | 12 | 0.49 |
| C_s7 (linear + B repulsions) | 7.56 | 9 | 9 | 7.56 | 1.00 | 2.24 | 26k | 37 | 12 | 0.34 |
| C_s8 | 6.08 | 9 | 7 | 5.88 | 0.97 | 0.84 | 36k | 42 | 12 | 0.32 |
| D_s7 (pi1-tie + A repulsions) | 0.08 | 1 | 0 | | | | never | | | |
| D_s8 | 0.08 | 1 | 0 | | | | never | | | |

-> B ~2x A in vesicle count, forms 2-3x faster. Neither ingredient alone does it: the stronger tail
repulsions on the linear lipid (C) give a few more but mostly networked lumens (iso 0.8-2.2);
the pi lipid with A's repulsions (D) gives none. B as a whole is the best of the four.
Images (viewed): figs/judge/dbg_A_s8.png, dbg_B_s8.png, z_A_s8_c3.png, z_B_s8_mid.png: both are genuine
bilayers around an N lumen with catalysts; A thick H-T-T-T bilayer, vesicle area ~90-140, several
N/K droplets wrapped by lipid but not counted; B thin bilayer of H2T2 rectangles, smaller vesicles
plus many loose bilayer ribbons (excess lipid) and a few unclosed N/K droplets.
### Batch 2 (done 03:45): crossings (dense 100k->130k, snap every 100 = 900 tau) and 100k->200k
Dense branches: runs/judge_{A,B}_s{7,8}_dense; continuation snapshots at 130k are cmp-identical to
the dense branches (determinism OK). cross2.py (memA tool, used by both teams) -> cross2_*.json/.txt.

| run | cells | tracks | tracks >=300 tau | Ka exits | Ka entries | N exits | N entries | N entry /len/tau | free N out |
|---|---|---|---|---|---|---|---|---|---|
| A_s7 | 3.9 | 24 | 3 | 0 | 0 | 6 | 0 | 0 | 102 |
| A_s8 | 7.1 | 14 | 9 | 0 (+1 out-and-back in a gap) | 1 (same bead) | 5 | 2 | 9e-6 | 157 |
| B_s7 | 9.2 | 60 | 11 | 0 | 1 | 6 | 69 | 3.2e-4 | 27 |
| B_s8 | 9.2 | 62 | 11 | 4 | 8 (one group of 8 at 112000) | 38 | 89 | 4.3e-4 | 34 |
B_s8 Ka exits inspected by eye (figs/judge/zx_B_s8_121300.png, zx_B_s8_121400.png, zx_B_s8_128100.png): all through an open wall
gap of a vesicle whose wall is partly a loose ribbon (the N lumen itself spills out there); no
catalyst crossed an intact bilayer in any run. B: many short-lived tracks (detector flicker of
small vesicles near the area threshold, ribbons opening/closing) but as many long-lived vesicles.
N exchange: A practically none at equilibrium; B ~30-40x higher entry rate per membrane length.

Long run (100k -> 200k, chem 0): cells per 10k steps
A_s7 ... 4,2,6,7,2,4,4,4,3,4 (150-200k mean 4.4, all with K); A_s8 7,5,7,7,5,7,6,7,6,7,6 (6.6)
B_s7 11,11,9,9,10,8,12,10,8,8,8 (8.9, 7.9 with K); B_s8 11,8,9,8,8,6,7,9,8,5,10 (8.4, 7.7 with K)
-> A does not coarsen (stable but few); B coarsens slowly (~11 -> ~8.5) and ~10 % of B cells
are then catalyst-free; B still 1.3-2x A at 200k.

### Batch 3 (done 03:48): chemistry stress test, same chemistry for A and B, from the 100k ckpts
chem=1, p_syn_b 6e-3, p_rep 1e-4, mu 0.02, p_ld 2e-6, p_kd 5e-6, p_nd 1e-6, uniform feed 1e-4 cap 0.11,
30k steps; F = p_syn_a 2e-3, S = p_syn_a 2e-4. Cells (tools detector) at 100k,105k,...,130k:
| run | cells | max bond | T | syn |
|---|---|---|---|---|
| A_s7 F | 7,5,1,0,0,1,1 | 1.285 | 0.989 | 905 |
| A_s8 F | 7,5,0,0,1,1,0 | 1.329 | 0.989 | 908 |
| B_s7 F | 11,2,0,1,1,3,3 | 1.291 | 0.983 | 1107 |
| B_s8 F | 11,4,1,0,2,2,3 | 1.232 | 0.983 | 1157 |
| A_s7 S | 7,7,4,4,3,4,3 | 1.142 | 0.991 | 238 |
| A_s8 S | 7,5,6,6,7,7,3 | 1.112 | 0.990 | 186 |
| B_s7 S | 11,11,7,7,6,7,6 | 1.149 | 0.985 | 242 |
| B_s8 S | 11,8,7,6,11,11,7 | 1.192 | 0.984 | 218 |
-> both lose their N lumens to synthesis (F: all gone in ~10k steps; S: ~half gone in 30k). Same
problem for both teams (lumen = N phase). B keeps more vesicles (6-7 vs 3). No bond > 1.4 anywhere.

Speed (2 threads, L=100, 4000 steps from the 100k ckpts, 3 interleaved reps, load ~3.5 from the
other agent): A 1.28-1.53 ms/step, B 1.18-1.36 ms/step -> equal within noise.
Formation speed: first >= 3 cells A 32-36k steps, B 10-14k steps.

Images viewed: figs/micro_A_s8_100k.png, micro_B_s8_100k.png, goodsell_A_s8.png, goodsell_B_s8.png
(all > 2 MB, not copied: `runs/judge_src/figs/`, pad op de ontwikkelmachine).
A: fewer, bigger, cleaner vesicles with thick walls, little debris. B: ~2x more, smaller vesicles with
thin bilayers + many loose bilayer ribbons (excess lipid) in between. Both genuine closed bilayers.

## 3. DECISION: winner = B (memB final physics, which already contains A's two-phase nutrient idea)
Reasons: 1.5-2.6x more closed vesicles at 100k (9.7/11.3 vs 4.3/6.6), 1.3-2x at 200k; forms 3x
faster; ~30-40x higher N permeability (A: N barely re-enters, the life team's main blocker); keeps
more vesicles under slow synthesis; same speed per step; catalysts never cross an intact bilayer in
either (B: 4 escapes through an open wall gap in one of two 900-tau windows). The controls show the
gain needs B's lipid AND its strong tail repulsions together (C, D). No merge beats B.
Costs of B: engine change (lipid template), loose ribbons, slow coarsening, ~10 % empty cells later.

## 4. Port (judge_src/port)
- port/oercel.c = memB_src/oercel.c + comments neutralised + verbatim old code for lip_arch=linear
  in 5 places (bonded forces, overlap energy, synthesis placement, relaxation, soup init).
  Reason: memB's template code gives the same maths but different FMA contraction, so linear runs
  were NOT bitwise identical to the old engine (memB's claim was wrong; verified: identical with
  -ffp-contract=off, different without). With the verbatim branches:
  * linear chem=0: identical to old engine (memA 5000 steps; soup_env with vent/stir/kT cycle and
    synthesis 3000 steps; H-H-T-T-T-T 3000 steps) and the full memA_z25 100k reproduction
    (judge_repro_A: snapshots 50k/100k, stats.csv, ckpt.bin cmp-identical);
  * pi (final): identical to memB binary incl. chemistry (B_form 5000, B_chem 3000 with 160 syn)
    and the full memB_F01 100k reproduction (judge_repro_B: cmp-identical);
  * linear WITH synthesis: diverges from the old engine in the last bit at some syntheses (first at
    step 2550 of soup_small: 3 beads of the new lipid, 1 ulp). Cause: GCC inlines/contracts the
    chemistry function differently in the bigger translation unit (old chemistry/relax/overlap text
    copied verbatim still differs: 105 vs 36 FMA instructions). Statistically equivalent; documented.
- make test (forcetest 3 boxes + molforcetest 10 templates) PASS.
NEXT: install into engine/, make, make test, validate.sh, README, params/membranes.ini, final soup
run (checkpoint), images.

### Install (04:14)
- engine/oercel.c, engine/oercel (atomic mv, md5 b727b932...; `make -B` in engine/ rebuilds the same
  md5), engine/Makefile (+ tests/molforcetest, in `make test`), engine/tests/molforcetest.c (from
  memB, comments neutralised), engine/tests/validate.sh (+ section 8: membrane lipid),
  engine/tests/snapcheck.py (read_ckpt reads version 3), engine/params/membranes.ini (memB physics,
  new header). Old engine source kept in runs/judge_src/oercel_engine_orig.c (md5 f760b805...).
- validate.sh (runs/judge_validate): 0 failed checks (37 checks; sections 1-7 numbers identical to
  README; section 8: molforcetest 10 templates, pi restart identity ckpt v3, pi soup with 490
  syntheses max bond 1.218, <T> 0.981, 0 broken molecules).
NEXT: final soup run runs/membranes_final (membranes.ini as-is, final engine) -> checkpoint; compare
with memB_F01 (must be bitwise identical); images; README.

### Final (04:16-04:24)
- runs/membranes_final: `engine/oercel engine/params/membranes.ini runs/membranes_final walltime=530`
  -> done at 100000 in 139 s (1.39 ms/step, 2 threads). snap 50k/100k + ckpt.bin cmp-identical to
  runs/memB_F01_wt200_kb300; 101 common stats rows identical. jcells: 13.44 mean (2nd half), max 17,
  last 14, 100 % with catalysts, first >= 3 at 10k, median area 27, K/cell 10. Images viewed:
  runs/membranes_final/figs/micro_100k.png (4.6 MB, not copied), cells_100k.png
  (copy: figs/membranes_final/cells_100k.png).
- validate.sh: 32 PASS, 0 FAIL (validate_final.log). Scalar build (-DOERCEL_SCALAR): forcetest +
  molforcetest PASS. syn_nN path (pi nT=2, syn_nN=4, L=32, 6000 steps): 137 syntheses, 0 broken
  molecules, max bond 1.17.
- Open for the next teams: lumen = N phase (synthesis eats it); loose ribbons; slow coarsening;
  linear-lipid runs WITH synthesis are not bitwise identical to the pre-template binary.
