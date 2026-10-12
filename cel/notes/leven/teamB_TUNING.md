# lifeB - emergent growth and division: tuning notes (crash-safe log)

Agent lifeB. Strategy: the ENVIRONMENTAL route = metabolism + uniform environmental physics
(gentle Kolmogorov stirring, slow temperature cycles). SPEC section 0: only laws + environment;
start = random soup (init=soup with membranes physics) or a branch of the soup checkpoint
runs/membranes_final/ckpt.bin (step 100000, soup seed 1, L=100, 14 detected vesicles).

Private engine copy: runs/lifeB_src (copied from cel/engine, md5 b727b932 = engine/oercel).
Runs: runs/lifeB_*. Final params (when found): runs/lifeB_src/params/life.ini.

## 0. Status / resume pointer (READ FIRST, updated after every batch)

(Times written in headings before ~06:50 were my own estimates and can be off by up to an hour;
later ones were read from the system clock. The order of entries is the true order.)

- Tools written: scan/branch.sh (one 540 s chunk of a branch; continues from own ckpt),
  scan/batch.sh JOBFILE (2 jobs x 1 thread in parallel), scan/vstat.py RUN --table --div
  (tools/cells.detect per snapshot, cached in RUN/lifeB_cache; content-based tracking with
  permanent bead ids, gap bridging 3 snapshots; split candidates), scan/zoom.py (zoomed bead
  plots, --agg colours membrane aggregates).
- params/life_base.ini = membranes.ini physics + chem=1 + judge "S" rates (per-run overrides on
  the command line, recorded in each run's params.ini).
- Speed: L=100, 1 thread: 2.3 ms/step (30k steps in 70 s with 2 jobs in parallel).

- STATUS 05:30: no clean division yet. Findings: (1) N influx ~0.024 N/tau per vesicle with the
  feed (enough for slow growth at p_syn_a ~1.5e-4); (2) the feed's free N bridges vesicles ->
  fusion/coarsening; (3) big floppy K-vesicles make lobes/septa that refuse; (4) Kolmogorov
  stirring n=4: shear 0.024 harmless, 0.048 stretches vesicles into dumbbells that PINCH (H1
  144k-146k, by eye) but daughters end in ribbon networks / refuse; >= 0.1 opens membranes,
  0.19 shreds; (5) temperature (constant or cycles) weak lever, speeds coarsening.
  Engine additions (private copy): stir_mode=cells, stir_period/stir_duty, feed_period/feed_duty.
  Current binary md5 13675eae (oercel_orig_b727 = team engine).
- NEXT: D1 batch (day/night feed), C2 (convection cells from G1a_286k), KC (catalyst-condensate
  formation), I1 (intermittent strong Kolmogorov). Job files in scan/jobs*.txt; a run continues
  with `scan/batch.sh JOBFILE` (each call = one 540 s chunk per job).

- STATUS 07:05 (clock): FIRST EMERGENT DIVISIONS in my runs: C3a = membranes_final + slow
  metabolism (G1 rates) + steady CONVECTION CELLS (stir_mode=cells, n=2, A=2.5e-3, strain ~0.03):
  2 verified divisions (170k->174k symmetric ~28/31 K; 124k->126k asymmetric ~7/20 K), images in
  runs/lifeB_C3a_cells_n2A25e-4/figs. Not yet: repeated divisions, replicate, official tracker
  (it misses them: fast advection + undetected neck stage). Running: C3c replicate (seed 2) and
  SOUP1 (params/life_draft.ini from a random soup). Then: C3a to 700k, C3d/C3e (A 2e-3/3e-3).

- FINAL STATUS (08:00 clock): partial success. Emergent divisions of catalyst-containing vesicles
  into two closed daughters with catalysts DO occur with the environmental route (steady
  convection cells, stir_mode=cells, strain ~0.03, + slow metabolism), verified by eye in 4 runs
  (C3a, PROD2 incl. one 2nd-generation division, V1, C3e) - see the tally in section 1 and the
  V1 entry at the end (V1 207k->221.5k: 123 K -> ~68 + ~56 K, the cleanest one). But they are rare (~1 per 100k steps per L=100 box), often asymmetric
  or messy, granddaughters fuse again, and the official tracker (tools/analyze.py) registers none
  of them (detection gaps at the neck). Final params: params/life.ini (from a random soup; = run lifeB_V1_flip15 bitwise).
  Conclusions and next steps: section 3. Best checkpoint: ckpts/C3a_165k.bin.

## 1. Batches

### Batch P (permeability vs a_T_N), branches of membranes_final at 100k, 30k steps
Only the feed on (p_feed 1e-3, cap 0.13: N 3000 -> 3900 within ~1k steps), no reactions/decay.
| run | a_T_N | detected cells 100k -> 130k (every 3k) | persistent-track N uptake |
|---|---|---|---|
| P1 | 120 (base) | 14 12 13 14 12 14 12 15 13 14 13 | 11 tracks: N 790 -> 1013 in 900 tau = 0.0225 N/tau/vesicle |
| P2 | 90 | 14 8 8 7 8 12 6 9 5 8 10 | fewer vesicles; 4 persistent tracks 348 -> 494 |
| P3 | 70 | 14 8 6 7 7 6 7 3 3 8 2 | vesicles fall apart |
| P4 | 55 | 14 2 1 2 3 4 1 1 0 2 2 | destroyed |
Learned: a_T_N must stay ~120 (as memA found for its lipid: lowering it dissolves vesicles).
Most of the extra outside N goes into the big UNCLOSED N/catalyst droplets (partly wrapped,
N touches water through gaps; seen in tools/debug_cells image), not through closed bilayers.
Influx into closed vesicles ~0.02 N/tau each -> a doubling (~300 N) needs ~15000 tau (~500k
steps) if influx-limited.
Global enclosed-region count (scan/glum.py: all lipid beads stamped, complement components on
the torus, not tied to one aggregate) shows that at a_T_N 90/70 most compartments still exist
(14-16 / 11-17 with K vs 15-18 at 120): the team detector undercounts because walls made of
several tail-contact aggregates or with 1-bead gaps fail its tests. N partition into the
bilayer core (scan/ncore.py, N with >=3 T neighbours and T majority, per 1000 lipids):
a_T_N 120: 0.07, 90: 0.27, 70: 1.4, 55: 4.3 -> permeability knob; 70 = 20x the base.
(glum-based exchange counting is useless: raster leaks make compartments flicker.)

### Batch C1 (chemistry, no environment), branches of membranes_final at 100k, 1 thread
| run | changes vs life_base | result (to ~240k) |
|---|---|---|
| C1a | p_ld 2e-5 (p_syn_a 2e-4) | lumens eaten: N inside compartments 2024 -> ~1100-1300, K inside 255 -> 480, K total 300 -> 950 (p_rep 1e-4 >> p_kd: exponential K growth), lipids 1500 -> 2160; detector cells 14 -> 3-8 (flicker) |
| C1b | p_syn_a 1e-3, p_syn_b 3e-3, feed 1e-3 cap 0.12, p_ld 2e-5 | lipids 1500 -> 3300: lipid networks/sponge enclosing water (W inside compartments 35 -> 8000), catalysts clump into dense clusters in lipid pockets. Not cells. |
Learned: the lumen is a pure N condensate, so its chemical potential does not drop when the
catalysts consume it: there is no driving force for N influx except outside supersaturation.
Consumption is proportional to catalyst count (grows exponentially with p_rep > p_kd), influx
to perimeter. Synthesis must be << 2e-4 per K per check at a_T_N 120, or permeability raised.

### Tools added (scan/)
- glum.py: global enclosed regions (all lipid beads stamped r=0.75 on a 0.25 grid, torus
  components; largest = bulk). Diagnostic only.
- kdiv.py RUN [--pre 3 --post 3]: catalyst-based division candidates: catalysts (permanent
  gids) that shared one compartment (area >= 16) for `pre` snapshots and then sit in >= 2
  different compartments (area >= 16) in each of the next `post` snapshots. Sanity: with
  pre=post=1 it finds flicker splits of huge networks in C1a, with 3/3 none -> filter works.
- follow.py RUN TRACK (or --list): zoomed panels following a vstat track.
- ncore.py, nexch.py: N partition into the core / (useless) exchange count.
- NOTE: `until ! pgrep -f PATTERN` waiters deadlock because pgrep matches the waiter's own
  command line; run combined job files instead.

### Batch G1 / S0 (running 04:47): G1 = growth balance vs permeability: p_syn_a 1e-4,
p_syn_b 3e-4, p_rep 3e-5, p_kd 1e-5, p_ld 2e-5, p_nd 0, feed 1e-4 cap 0.12; a_T_N 120/95/80/65.
S0 = stirring calibration on the 100k vesicles, chem 0: stir_A 2e-4/5e-4/1e-3/2e-3 (L=100,
n=1: u0 = 768 A, max shear 48 A, flow builds up in ~770 tau = 25k steps).
Next queued: jobsT0.txt = temperature calibration (kT 1.15, 1.3; kT_amp 0.25/0.4 P=300) with
the P1 feed and no reactions, plus P1 extended to 160k as control.

### Results G1a/G1b (to 286k) and S0a/S0b (to 160k)  [scan/summ.py: det = tools detector cells,
comp16K = glum compartments with K and area >= 16]
| run | det cells 100k->end | comp16K | median area of K-compartments | lipids | K | splits (kdiv 3/3) |
|---|---|---|---|---|---|---|
| G1a a_T_N 120 | 14 -> 7 | 17 -> 8 | 30 -> 75 | 1500 -> 1663 | 300 -> 430 | 0 |
| G1b a_T_N 95 | 14 -> 2-6 | 17 -> 10 | 30 -> 61-97 | 1500 -> 1662 | 300 -> 460 | 0 |
| S0a stir 2e-4 (n=1), chem 0 | 14 -> 9 | 17 -> 12 | ~30-35 | - | - | 0 |
| S0b stir 5e-4 (n=1), chem 0 | 14 -> 13 | 17 -> 13 | 26-59 | - | - | 0 |
G1: lumens keep their N (N inside K-compartments ~1600-2200) at p_syn_a 1e-4, but the
vesicles COARSEN by fusion (fewer, bigger: area 30 -> 75); several big N/K droplets are only
partly wrapped (debug image G1a 286k). Growth of lipids is slow (+11 % in 186k steps) because
p_ld 2e-5 x ~50 lipids ~ p_syn 1e-4 x ~10 K. No splits. S0: up to stir 5e-4 (max shear 0.024)
vesicles survive; loose ribbons align with the flow; no splits.
Idea now tested (S1): shear breakup of the big coarsened coacervate-vesicles (droplet breakup
needs capillary number ~ R*eta*shear/tension ~ O(1): big ones break first) + re-wrapping by the
membrane, the same process that formed the vesicles. S1 = branches of G1a at 286850 (ckpt
copied to lifeB_src/ckpts/G1a_286k.bin), same chemistry, stir_n 4 (u0 = 48 A, max shear 12 A
at L=100; flow builds in ~50 tau), A = 2e-3, 4e-3, 8e-3, 1.6e-2 (shear 0.024 ... 0.19).

### G1c/G1d (a_T_N 80/65, to 274k) and S0c/S0d (stir n=1 1e-3/2e-3, chem 0, to 160k)
- G1c/G1d: no better than 120 (detector 1-7 cells, comp16K 5-17 fluctuating, coarsening to
  area 80-110); lower a_T_N gives no visible benefit -> keep a_T_N 120.
- S0c (max shear 0.048): coarsening 17 -> 9 compartments; S0d (0.096): N/K droplets are
  stretched along the flow into strips ~40 long, membranes open at the ends, droplets merge;
  NO breakup (2D: a stretched droplet strip has no capillary (Rayleigh-Plateau) instability).
  => shear alone does not break droplets/vesicles in 2D at shear <= 0.1; strong shear opens
  membranes ("shredding" direction), also coalescence.
- G1a event counts (186k steps): 702 syn (= p_syn x K x checks: NOT nutrient limited), 536
  dlip, 185 rep, 61 dK; fed 3788 N. Influx kept up with consumption at p_syn_a 1e-4.
- Images (C1a track 0, zoom): with synthesis inside, the wall gets THICKER (second bilayer /
  multilamellar patches) instead of the lumen growing: the lumen volume limits the vesicle.
- New tool scan/cond.py: N/K condensate droplets (N+K clusters r<0.85, >= 40 beads) with
  catalyst-based split detection, independent of membranes; scan/kfollow.py: panels centred
  on a catalyst group. G1a: 3 condensate 'splits' (53->50+3 K, 71->62+9, 17->15+2). Checked
  the 248k one by eye (kfollow): a big elongated K-vesicle pinches off a small lobe with 9 K
  (separate compartment at 250k-254k) which FUSES BACK by 256k. => spontaneous budding of
  big floppy vesicles exists; the daughters stay adjacent and refuse.
  Hypothesis: stirring can carry pinched daughters apart before they refuse (S1 tests).

### S1 results (branches of G1a 286850, stir n=4, to ~350k for a/b)
- S1a (A 2e-3, shear 0.024), S1b (4e-3, 0.048): big K-rich vesicles (K up to 50 % of the
  lumen) form transient lobes and SEPTA (theta: one bilayer between two lumens inside one outer
  membrane) that dissolve again within ~5-10k steps (S1a 311k-319k, checked by eye with
  kfollow: the lower lobe with ~28 K is a separate compartment 311k-316k, re-merged at 317k);
  also inner water vesicles (invaginations pinched inward). Condensate splits (cond.py):
  S1a 3, S1b 5 in ~60k steps (G1a: 3 in 186k). dscore (kdiv-based, separate compartments
  for >= 3-5 snapshots): 0-1 candidates, none clean.
- S1c (A 8e-3, shear 0.096): few splits, wrapping falls to ~0.74.
- S1d (A 1.6e-2, shear 0.19): SHREDDING: droplets torn into pieces, membranes stripped into
  ribbons (wrap 0.0-0.5) - checked by eye (kfollow 287k-295k). Not division.
- Septum (theta) states do not resolve into two separate vesicles: the tied lipid penalises
  the T-junctions, so the septum retracts. A clean 2D fission needs a furrow (a finger of
  outside medium lined by two bilayers) crossing the lumen, i.e. a deflated/necked vesicle.

### Queue (05:20): T0 (temperature calibration) -> H1 (from membranes_final 100k: p_syn_a
1.5e-4, p_syn_b 4.5e-4, p_rep 4e-5, p_kd 2e-5, p_ld 4e-5, feed 1e-4 cap 0.12; H1 stir n4
4e-3, H2 n4 8e-3, H3 no stir, H4 n4 4e-3 + kT_amp 0.15 P 600) -> KC (new idea, below).

### Idea KC: catalyst-condensate lumen (plan B for the 'lumen = food' problem)
The N-phase lumen is the food itself: consumption shrinks the lumen, its chemical potential does
not drop (pure phase), so there is no real gradient for uptake. Swap roles: catalysts form the
condensate (a_W_K 45, a_H_K 22, a_T_K 200, f_Ka 0.08, like N in membranes.ini), nutrient N is
dissolved (a_W_N 25, a_H_N 25) and mildly enriched in the catalyst phase (a_N_K 20/15), with
a_T_N 120/80. Then synthesis needs >= 4 N within r_cat -> rate falls with internal N
(self-regulating), and uptake is driven by a real gradient; the lumen grows by K replication.
Formation test from a random soup (scan/soup.sh, jobsKC.txt): KC1 a_T_N 120 a_N_K 20,
KC2 a_T_N 80 a_N_K 15, chem 0, 80k steps.

## 2. Engine changes in this private copy (laws/environment only)
- (05:20) Environment: `stir_mode = kolmogorov | cells` and a stirring on/off cycle
  `stir_period`, `stir_duty` (defaults: kolmogorov, 0 = always on, 1). `cells` = steady
  convection cells (like thermal convection cells in a pond): every bead gets
  f = A (sin kx cos ky, -cos kx sin ky), k = 2 pi stir_n / L, net force removed (both
  components, fixed-block sums, thread-count independent). The cycle switches the whole
  stirring on during the first stir_duty fraction of every stir_period (tides/storms): global,
  time-only, structure-blind. Code: stir_at(), force_init(); orig source kept as
  orig_oercel.c, old binary as oercel_orig_b727.
- Checks: tests/forcetest.c extended with the cell mode vs O(N^2) brute force (max diff 2.1e-13,
  1 vs 4 threads bitwise identical) -> FORCETEST PASS. New binary vs old binary, 1500 steps from
  membranes_final with chemistry + Kolmogorov stirring + kT cycle, and without stirring:
  snapshot, checkpoint, stats, events bitwise identical (cmp).

### T0: temperature (branches of membranes_final 100k, feed 1e-3 cap 0.13, no reactions, 60k steps)
| run | env | comp16K 100k -> 160k | N inside K-compartments | median area | N-core partition /1000 lip |
|---|---|---|---|---|---|
| P1 (control, extended) | kT 1 | 17 -> 16 | 2005 -> 2707 | 30 -> 42 | 0.07 |
| T0a | kT 1.15 | 17 -> 8 | 2005 -> 1915 | 30 -> 65 | 0.10 |
| T0b | kT 1.30 | 17 -> 6 | 2005 -> 544 | 30 -> 40 | 0.13 |
| T0c | kT 1 + 0.25 sin(2 pi t/300) | 17 -> 14 | 2005 -> 2832 | 30 -> 46 | - |
| T0d | kT 1 + 0.40 sin(2 pi t/300) | 17 -> 10 | 2005 -> 2869 | 30 -> 81 | - |
Learned: heating hardly raises the N partition into the core (0.07 -> 0.13) but speeds up
fusion/coarsening and opens vesicles (kT 1.3 loses most). Temperature cycles do not raise the
N uptake beyond the constant-kT control (2832 vs 2707) and coarsen more at amp 0.4. The
detector count oscillates with the cycle (fewer closed walls in the hot phase).
=> temperature is a weak lever here; not used further for uptake. (Cooler would slow coarsening.)
- (05:40) Environment: day/night cycle of the food supply, `feed_period` (time units, 0 = always
  on) and `feed_duty` (fraction of each period, at its start, with the supply on). Global and
  time-only (like sunlight-driven nutrient production); feed_supply() returns early at night.
  Checks: default path bitwise identical to the previous binary (1500 steps, chem + feed + stir:
  ckpt/events/stats cmp-identical); with feed_period 30, duty 0.5 over 1500 steps all 99 feed
  events fall in the day halves (steps x000-x499), none at night. Binary md5 in section 0.
- (07:50) Restart determinism with ALL new options on (L=32 soup, life.ini laws, stir_mode=cells
  A 0.03, stir_period 3 / duty 0.5, feed_period 6 / duty 0.5, fast chemistry): 900 steps in one
  go vs 450 (1 thread) + restart to 900 (2 threads): snapshot, checkpoint, stats.csv and
  events.csv (14 syn, 2 rep, 36 feed) bitwise identical (cmp).

### Note from the other life team (lifeA, internal route; read from runs/lifeA_src/TUNING.md 05:30)
lifeA c06 (closed system: no feed, no replication, no decay, p_syn_a 5e-4, from membranes_final)
saw a verified emergent division: synthesis turns lumen N into membrane, reduced area falls,
vesicle elongates, necks and splits into two separate closed vesicles with catalysts (~25k steps
after the start). They also report that free N in the water (from the feed) wets the outer head
layers and merges vesicles into networks -> the feed drives the coarsening I see in G1/P1/T0.
=> Plan D (environmental): a DAY/NIGHT cycle of the food supply (new engine option feed_period,
feed_duty): night = no feed, outside N used up, vesicles deflate by synthesis (division window,
less N bridging); day = feed, lumens refill by permeation. Balance estimate: influx ~0.024
N/tau per vesicle (P1) vs consumption 4 p_syn n_K / 0.3 tau; for net excess membrane AND lumen
growth need 0.53 I < C < I (from d ln P = 1/2 d ln A with n_lip ~50, N_lumen ~90) ->
p_syn_a ~1.5e-4 with ~10 K. p_ld 5e-6 (empty vesicles lose ~1/2 of their lipids in ~1.4M
steps); H runs used p_ld 4e-5 which exceeds synthesis for a 10-K vesicle (equilibrium size
n_K p_syn / p_ld = 37 lipids) - lipids fall 1500 -> 1440 there.
Queue (05:31): H1-H4 running/next -> D1 (D1 day/night 3000 tau, duty 0.6, feed 1e-3 cap 0.13;
D2 = D1 + stir n4 4e-3; D0 constant feed 1e-4 cap 0.12; D3 = D0 + stir) -> C2 -> KC -> I1.

### Physical picture (05:35) and batch E
Energetics: a bilayer-covered N droplet stores excess lipid more cheaply as extra layers or
ribbons than as extra perimeter, and two small vesicles have more bending energy than one big
one, so division is NOT spontaneous at equilibrium: it needs work (shear) or an active process.
Szostak-like picture: synthesis makes a vesicle FLOPPY (excess perimeter, low tension) ->
gentle shear elongates floppy vesicles (taut ones resist) -> neck -> pinch -> the flow carries
daughters apart (refusion avoided). H1 144k-146k shows this sequence. Requirements: synthesis
fast enough for excess perimeter, few loose ribbons (they bridge vesicles into networks; cleared
by p_ld), little free N outside (bridging), shear ~0.03-0.05.
E1/E2 (replacing D0/D3 in jobsD1.txt): p_syn_a 3e-4, p_syn_b 9e-4, p_rep 6e-5, p_kd 2e-5,
p_ld 3e-5, p_nd 0, feed 1e-4 cap 0.11, Kolmogorov n=4 A 3e-3 / 5e-3 (shear 0.036 / 0.06).
H1 (n4 A 4e-3, shear 0.048) / H2 (8e-3, 0.096) from fresh vesicles to ~280k: H1 compartments
with K 17 -> 2-7 (degrading), H2 destroyed (0-3). Continuous shear >= 0.048 is too strong for
the fresh small vesicles in the long run -> E2 changed to A 2e-3 (0.024), D2 to 2.5e-3 (0.03).

### H3/H4 (to ~305k) and detector-based division finder
- H3 (no stir, p_ld 4e-5): compartments with K 17 -> 8-12, median area 30 -> 40-100, K 300 ->
  491 (dense K clusters), lipids ~1500 (ribbons decay, K-vesicles hold). H4 (stir 4e-3 + kT
  cycle 0.15/600): 17 -> 5, coarse. No clean division in H1-H4.
- scan/ddiv.py: division finder on the TEAM detector (vstat cache) + catalyst gids: a detected
  cell's catalysts later found in >= 2 detected cells in different membrane aggregates, kept
  apart for `post` snapshots. Positive control: it finds lifeA's verified c06 division
  (parent@126k K22 -> @134k K13 + K10, different aggregates) with --jmax 15 --post 1 (that
  pair is detected as two cells in only one snapshot). With --jmax 15 --post 1: G1a, S1a-c,
  C1a/b, P1, T0c: 0; H1: 1 (checked by eye: elongated vesicle in a ribbon network, its
  'partner' is another compartment - NOT a division); H3: 1 (not checked yet).
- Analysis caches for other teams' runs go to the scratchpad (never written into their dirs).

### D1/D2 (day/night feed, to ~262k) and E1/E2 (partial)
- D1 (feed 1e-3 cap 0.13 only in the first 60 % of every 3000 tau; p_syn_a 1.5e-4, p_ld 5e-6):
  N falls 3900 -> 2831 each night (consumption ~0.9 N/tau total), refilled at dawn; lipids
  1500 -> 2185 (excess, p_ld too low), compartments with K 17 -> 9 (coarsening). 1 ddiv
  candidate (153k->158k), checked by eye: the catalyst group stays in ONE vesicle - not a
  division. D2 (+ stir 2.5e-3): similar, 0 candidates. Outside N does not vanish at night
  (p_nd 5e-6 is too slow), so the night is no 'closed system'.
- E1/E2 (p_syn_a 3e-4, p_ld 3e-5, stir 3e-3 / 2e-3) at 133k: compartments 17 -> 7-11, N in
  K-compartments 2005 -> ~950 (consumption > influx), no candidates yet.
Diagnosis: the ATPS lumen IS a separate condensed phase; the medium is either undersaturated
(no uptake) or supersaturated (naked N droplets that bridge/fuse vesicles, Ostwald ripening).
Next: KC (catalyst condensate + fully miscible nutrient: no outside droplets possible, real
concentration gradient, K cannot ripen across membranes) formation test queued after E.
- E1/E2 final (~229k): compartments with K 7-13, N inside them 2005 -> 400-1180 (eaten),
  lipids 1500 -> 2000 (excess), 0 / 1 ddiv candidates (E2: 44 K -> 42 + 3, a fragment).

### KC formation (catalyst condensate, N miscible), random soup L=100, chem 0, 80k steps
| run | recipe | detector cells with K at 80k | K-compartments (glum) | notes |
|---|---|---|---|---|
| KC1 | f_Ka 0.08, c_N 0.05, a_W_K 45, a_H_K 22, a_T_K 200, a_W_N 25, a_H_N 25, a_T_N 120, a_N_K 22 | 6 (rising) | 10, ~60 K each | dense K droplets, many only partly wrapped; N enriched in the K lumen (N/(N+K) ~ 0.21 vs 0.05 bulk) |
| KC2 | f_Ka 0.10, a_N_K 20 | 3 | 5 | worse |
Note: in membranes.ini the tails tolerate N (a_T_N 120) much better than W (200), which makes
the lipid adsorb at the N/W interface; with a_T_K 200 there is no such preference for the K/W
interface -> KC3/KC4 'mirror' the N recipe for K: a_T_K 120 / 150 (a_H_K 22, a_H_N 22).
| KC3 | mirror of the N recipe for K: a_T_K 120, a_H_K 22, a_W_K 45; N: a_W_N 25, a_H_N 22, a_T_N 120, a_N_K 22; f_Ka 0.08, c_N 0.05; 100k | 6 (4-8 from 40k on) | 8-10, ~75 K each | big dense K droplets, many only C-wrapped (image debug KC3 100k) |
| KC4 | as KC3, a_T_K 150 | 6 | 8 | same |
Suspect: the dissolved N with a_T_N 120 / a_H_N 22 is lipid-friendlier than water and coats
membrane edges (co-surfactant, as memB saw for low a_T_N) -> KC5/KC6: N water-like towards
lipids (a_H_N 20, a_T_N 200; W itself crosses membranes at ~0.02 per tau per vesicle through
defects, memA z25d, so uptake should not depend on a_T_N), c_N 0.05 / 0.02.
| KC5 | as KC3 but N water-like towards lipids: a_H_N 20, a_T_N 200; c_N 0.05 | 4-7 | 9-14 | |
| KC6 | as KC5, c_N 0.02 | 7-10 (40k-100k) | 9-13, ~100 K each | GOOD: comparable to the N recipe; image debug KC6 80k: 9 detected + ~4 more closed-looking K vesicles, ribbons |
=> KC6 is a second vesicle-forming physics in which the lumen is a catalyst condensate and the
nutrient is a dissolved, water-like solute. params/kc_base.ini = KC6 laws + chemistry (the a-matrix
of a kc_base run equals KC6's exactly, checked with diff). Formation checkpoint copied to
ckpts/KC6_100k.bin (step 100000, soup seed 1).
Life batch L1 (06:25, from KC6 100k): p_syn_a 3e-3 (needs >= 4 N within r_cat; with ~7 % N in
the lumen only a few % of checks qualify), p_syn_b 9e-3, p_rep 2e-4 (>= 2 N), p_kd 2e-5, p_ld 1e-5,
feed uniform 5e-5 cap 0.04; L1a no stir, L1b stir n4 2.5e-3.
L1 results (to ~300k): synthesis is rare (L1a 484 syn in 200k steps: the K lumens hold only
~4 % N, so >= 4 N within r_cat is rare); lipids 1500 -> 1663; K 2400 -> 2223 (dK 917 > rep
723); 3-10 detected K-vesicles throughout (they persist); no divisions (L1a 1 ddiv candidate,
not checked, 61+3 K split = fragment). L1b (stir 2.5e-3) similar.
Queue (06:40): L2 (p_syn_a 3e-2: L2a cap 0.04; L2b cap 0.08 + stir) -> C3 (convection cells
n=2 from membranes_final with G1 chemistry, A 2.5e-3 / 5e-3: strain rate at the stagnation
points 12 A = 0.03 / 0.06, cell speed U = A/(2 nu k^2) = 96 A) + C2a/C2b (cells from G1a_286k).
Why cells: at a hyperbolic stagnation point a vesicle is pulled apart symmetrically and the two
halves are carried AWAY from each other (four-roll-mill geometry), unlike Kolmogorov shear
where they tumble and refuse.
L2 partial (to ~155k): L2a (p_syn_a 3e-2, cap 0.04): synthesis ~6 per 1000 steps, lipids
1500 -> 1727, detected K-vesicles 7 -> 9-11, K slowly falling; image: K droplets with thick
(multilayer) walls, some empty water vesicles, ribbons. L2b (cap 0.08 + stir): synthesis explodes
(1979 in 55k steps), lipids 1500 -> 3361, sponge (0-2 detected). The KC synthesis rate is a steep
function of the nutrient level (needs 4 N within r_cat).
Next (06:55): Q batch = lifeA's closed-system deflation regime (c06: p_syn_a 5e-4, no feed, no
rep/decay) reproduced as control Q0 and with environment: Q1 Kolmogorov n4 2e-3, Q2 cells n2
2.5e-3, Q3 cells n2 5e-3 (60k steps each) -> does the environment make the deflation divisions
cleaner/more frequent? Then C3.
- L2a final (263k): lipids 1500 -> 2368, sponge (1-2 detected): synthesis > lipid decay globally
  -> unbounded lipid; KC needs p_ld ~4e-5 to balance. Not pursued further for now.
- Q0 (closed system p_syn_a 5e-4) is BITWISE identical to lifeA's c06 (snap 130k cmp). Its
  division (lifeA's discovery) checked by eye with kfollow (figs/division_126k-140k_kfollow.png in
  runs/lifeB_Q0_closed_c06rep): elongation 126k, constriction 127-128k, two lobes on a neck
  130-131k, separate 132-134k, two closed daughters with ~10 K each drifting apart 136-140k.
  Lumens are then consumed (closed system: N 3000 -> 320 at 160k) -> not sustainable.
- Q1 (+ Kolmogorov n4 2e-3): 0 candidates (one sample).
Cell-cycle idea (emergent size control): consumption C ~ n_K, influx I ~ perimeter ~ R. With K
replication n_K grows -> C/I > 1 -> lumen deflates -> division halves n_K and R by sqrt 2 ->
C/I drops by 1/sqrt 2 -> daughters re-inflate -> repeat. Needs C ~ I (G1a-like rates), a steady
outside supersaturation, and suppressed fusion.
- Q2/Q3 (closed system + convection cells A 2.5e-3 / 5e-3): official-detector division
  candidates 0 / 0 (Q3's 1 is a coincidence of distant cells). Condensate splits with both
  parts wrapped (cond.py, wrap ~0.9-1.0): Q0 4, Q1 3, Q2 1, Q3 3 per 60k steps. Checked by eye:
  Q1 120k (45 K -> 25 + 20): the top lobe stays TETHERED to the body by a long thin membrane
  tube (no clean separation by 130k); Q3 109k (43 K -> 21 + 20): the cell flow stretches the
  vesicle into two lobes on a thin neck (110-111k), but the lobes come back together (116k)
  and re-merge (120k): in a steady cellular flow both halves stay on neighbouring closed
  streamlines. => stirring stretches/necks vesicles but has not produced clean separations.
- Queue: C3 (cells with G1 chemistry, running) -> R (07:15): deflation regime with feed:
  p_syn_a 2.5e-4, p_rep 3e-5, p_kd 1e-5, p_ld 1e-5, feed 1e-4 cap 0.11; R1 Kolmogorov n4 2e-3,
  R0 no stir; 400k steps.

### !!! C3a (07:25): FIRST DIVISIONS IN MY RUNS - convection cells + G1 chemistry
C3a = membranes_final 100k + G1 chemistry (p_syn_a 1e-4, p_syn_b 3e-4, p_rep 3e-5, p_kd 1e-5,
p_ld 2e-5, p_nd 0, feed uniform 1e-4 cap 0.12) + stir_mode=cells stir_n=2 stir_A=2.5e-3 (16
convection cells of 25x25, strain rate at the hyperbolic points ~0.03, cell speed U ~0.24).
ddiv (team detector + catalyst ids, --jmax 15 --post 1): 3 candidates to 263k. Checked by eye:
- 170k->178k (figs/div_170k_kfollow.png): vesicle stretched along the flow (166k), two lobes on a
  neck (170-172k), two SEPARATE closed vesicles at 174k with ~28 and ~31 K, carried apart into
  different flow cells, both detected 178-180k; right daughter round and closed to >= 195k.
- 124k->133k (figs/div_124k_kfollow.png): stretched vesicle, small lobe (~7 K) pinches off at
  ~126k, drifts away and stays a separate closed vesicle with its K to >= 145k (asymmetric).
- 176k->188k: not yet checked.
C3b (A 5e-3, strain 0.06): 0 candidates, vesicles degrade (2-5 compartments).
NEXT: continue C3a to 700k (do daughters grow and divide again?) + replicate C3c (seed 2) -> jobsR.txt.
- 176k->188k candidate checked by eye: the catalyst group stays in ONE vesicle (partner is
  another vesicle) -> NOT a division. So 2 of 3 C3a candidates are real divisions.
- Queued after jobsR (C3a to 700k + C3c seed-2 replicate): jobsC4 = C3d (A 2e-3), C3e (A 3e-3).
- BUDGET SLIP (06:34-06:49 clock time, ~15 min): a waiter I believed killed (old C3 chain)
  was still alive, so after L2 two chains ran at once (Q batch + C3a/C3b, then C3a/C3b
  continuation + C2a/C2b) = 4 single-thread processes of mine instead of 2. No run directory was
  written by two processes at once (checked start times: C2a/C2b started after the first C3a/C3b
  chunk ended, the second C3a/C3b chunk started after that). C2a/C2b ran to 386k. Lesson:
  verify with ps after killing waiters.
- Official pipeline on C3a (tools/analyze.py --jobs 1, to 321k): criteria 1 JA, 2 DEELS (219 of
  909 syntheses in a lumen; 151 new lipids in a cell wall at the next snapshot; rho 0.58),
  3 JA (5 growing cells, e.g. track 2: 50 -> 105 lipids, lumen 42 -> 80), 4 NEE (no division
  registered), 5 DEELS (Kb share in cells 0 -> 14 %), 6 JA. The official tracker records only
  'fusie'/'afsplitsing' events: its links need lumen-pixel overlap between consecutive snapshots,
  but in the convection cells vesicles move ~5-7 units per 1000 steps and the dumbbell/neck
  intermediate is often not a detected cell -> production runs use snap_every 500.
- C2a/C2b (cells A 2e-3/4e-3 from the coarsened G1a_286k state, 100k steps): 0 candidates.
  Divisions came from the fresh small-vesicle state (C3a), not from coarsened big vesicles.
- params/life_draft.ini: membranes.ini physics + C3a chemistry + cells stirring, init = soup,
  snap_every 500 (one law set from a random soup).
- scan/loop.sh JOBFILE N: repeats one-chunk batches until every job is done; branch.sh accepts
  SRC_CKPT = SOUP for runs from a random soup.
- Queue (07:05): after C3a/C3b chunk -> loop jobsP.txt: C3c (C3a laws, seed 2 branch of
  membranes_final, to 500k) + SOUP1 (life_draft.ini from a random soup, to 500k).
- C3a 263k->352k (continuation): 2 more ddiv candidates. 296k->301k (figs/split_296k_kfollow.png):
  an annular compartment around an inner vesicle breaks; a small piece with ~5 Ka + 2 Kb becomes a
  separate closed vesicle (303-310k) - messy but a real separation. 304k->315k
  (figs/neck_refusion_304k_kfollow.png): two lobes on a neck for ~10k steps, then RE-MERGE (320k);
  the lumen is by then mostly catalysts (K 300 -> 512 overall: p_rep 3e-5 > p_kd 1e-5 makes the
  vesicles catalyst-packed, lumen N consumed). Late C3a is crowded with ribbons/networks.
- (editing branch.sh while a batch used it caused a harmless 'syntax error' at the end of that
  chunk: bash reads scripts lazily; the engine chunks had finished normally. Do not edit
  running scripts.)
- scan/khist.py: history of the detector cells holding a catalyst group. C3a 170k division:
  parent assembled by fusion of smaller K-vesicles at ~150k (40 K, A 122, 133 lipids), detected
  only intermittently while stretched in the flow, at 170k A 184, 177 lipids, 60 K, 494 N ->
  178k daughters A 99 / 90, 94 / 63 lipids, 28 / 26 K (all from the parent), N 266 / 243 ->
  both persist (right one to >= 212k: A 74-91, lipids 63 -> 96, K 31 -> 36 incl. replication;
  left one to >= 204k: lipids 94 -> 116). Daughters grow; no second division seen yet.

### Replicate C3c (seed-2 branch) and SOUP1 (life_draft.ini from a random soup), status 07:10
| run | to | detected K-cells | ddiv (--jmax 40 --kmin 4) | by eye |
|---|---|---|---|---|
| C3c | 341k | 1-4 (fewer than C3a) | 0 | - |
| SOUP1 | 245k | 4-9 (vesicles DO form from the soup with chemistry + cells from t=0) | 3 | 179k->188k: a K-packed vesicle is stretched along a ribbon, splits at ~182k into two compartments (~20 K and ~45 K) that move apart; the large one stays a closed vesicle to >= 202k, the small one is closed at 188-193k but looks partly open by 202k (figs in runs/lifeB_SOUP1_life_draft) |
| C3a | 352k | 2-7 | 7 with the wider window | the 2 clean ones already listed |
Assessment: convection cells + slow metabolism give occasional emergent divisions, but they
are rare (~1 per 100k steps per box), not every replicate shows one, the daughters are
often catalyst-packed, and the box gets crowded with ribbons/networks. Not yet a robust cycle.
- Official-style fluorescence frames of the C3a 170k division (tools/render.py --kind micro --at
  centroid of the parent's catalysts, zoom 50): runs/lifeB_C3a_cells_n2A25e-4/figs/micro_*.png and
  micro_strip_166k-186k.png (viewed: elongated vesicle 166k, neck 170-172k, two separate closed
  vesicles with GFP catalysts 174k, both closed 178k, right daughter round at 186k).
- Honest note on growth mode: the 170k parent was assembled by FUSION of smaller K-vesicles
  (~150k) before it was stretched and divided; metabolic lipid growth in C3a is slow (909 syn in
  252k steps for ~8 vesicles, ~45 lipids per vesicle per 100k steps).
- Why the official tracker (tools/tracking.py) misses the C3a 170k division: the parent is
  detected at 170k, then not detected at 172-176k (neck stage and freshly pinched walls with
  gaps), the daughters are detected from 178k; the tracker bridges at most 2 missing snapshots
  (max_gap) and links by lumen overlap or centroid distance < r_a + r_b, so parent and daughters
  are not linked. (tools are another teammate's area; not modified.)

### C3e (A 3e-3, strain ~0.036) and the production plan (07:25)
- C3e to ~270k: 4 ddiv candidates by 258k. Followed by eye (kfollow --det, 210k-243k): a group of
  67 K in two vesicles inside a membrane loop is stretched along a channel and ends as three
  separate closed vesicles (~35, ~17, ~8 K); khist: the 17-K daughter (227k) persists as one
  cell to >= 270k but slowly deflates (A 36 -> 22, N 97 -> 56): no second division seen.
- SOUP1 (life_draft, A 2.5e-3, from a random soup, to ~470k): vesicles form under the life laws
  (4-9 detected); 1 clear split (179k->187.5k, see above), others weak.
- params/life.ini = life_draft.ini with stir_A 3e-3, steps 700000, snap_every 500 (one law set
  from a random soup). PRODUCTION run lifeB_PROD1_life: life.ini, seed 3, 2 threads (started after
  SOUP1/C3e chunk ended; C3e stopped at ~400k).
- Official pipeline (tools/analyze.py) on SOUP1 (snap 500, to 500k): 1 JA, 2 DEELS (381 of 2105
  syntheses in a lumen; 241 new lipids in a wall), 3 JA (13 growing cells, e.g. track 302: 57 ->
  169 lipids, lumen 43 -> 111), 4 DEELS: the tracker confirms 7 'delingen' (15.5k, 41.5k, 243k,
  261.5k, 475k, 481k, 499k unconfirmed) but in all of them both daughters are in the SAME membrane
  aggregate ('eigen_membraan' false: septum/theta states or touching walls); only 15.5k has
  catalysts in both daughters (10 + 6). 5 DEELS, 6 JA (but mean lipid growth of tracks with
  catalysts is negative, -96 per 100k steps, vs +8 without: splits and fusions dominate the
  per-track slopes).
  On C3e (to ~400k): 4 NEE, 3 JA (2 growing), 6 JA (mean lipid growth with K +24, without +143:
  catalyst-free vesicles also grow, by absorbing ribbons/fusion - this violates the wanted
  'empty vesicles do not grow').
- PROD1 first chunk with 2 threads ran at ~5 ms/step (machine oversubscribed: lifeA 2 jobs + a
  third self-test process, load 5.3 on 4 cores -> OpenMP barrier stalls). Stopped cleanly at
  17828 (SIGTERM -> checkpoint) and continued with 1 thread; added PROD2 (life.ini, seed 4) as
  the second 1-thread job (results are thread-count independent). Loop: scan/jobsPROD.txt.

### Production PROD1 (life.ini, soup seed 3) and PROD2 (seed 4), 1 thread, snap 500 (07:48)
- PROD1 to ~250k, PROD2 to ~230k (stopped there to free the slots for the V test). Vesicles form
  from the soup under the life laws; detected K-cells 3-7; the box is crowded with bilayer
  ribbons that connect vesicles into networks.
- ddiv (jmax 40, kmin 4): PROD1 3 candidates, PROD2 0. By eye (runs/lifeB_PROD1_life/figs/cand_*.png):
  45.5k NOT a division (group stays in one vesicle); 86k: a ~5-K lobe becomes a separate
  compartment of a membrane network next to the 44-K vesicle (persists >= 12k steps) - borderline;
  136.5k: a small elongated vesicle with 11 K splits into 7 + 4 K compartments that stay apart
  (>= 20k steps) but both remain attached to ribbon networks - borderline.
- Next: V1/V2 = life.ini with f_lip 0.15 (fewer ribbons; V2 also p_ld 3e-5), soup seed 3, 300k.

## 3. Conclusions so far (07:50 clock) - for a successor
1. Growth: with the membranes.ini physics, catalyst vesicles take up N only through transient
   membrane defects (~0.02 N/tau per vesicle under a supersaturated feed); a_T_N 65-95 does not
   help and destabilises; temperature (constant or cycled) hardly changes uptake but speeds up
   fusion. Sustained lumen + membrane growth needs p_syn_a <~ 1e-4 per check (~10 K per vesicle).
   The lumen is the food phase itself, so faster synthesis eats the lumen (deflation) - which is
   also what drives lifeA's closed-system division (reproduced bitwise as Q0).
2. Environment: Kolmogorov shear (n=4) stretches vesicles; >= 0.05 opens membranes in the long
   run, 0.1-0.2 shreds them. Steady CONVECTION CELLS (new engine option stir_mode=cells) with a
   strain rate ~0.03 at the hyperbolic points are the gentlest effective forcing: they stretch
   large floppy catalyst vesicles until they neck and pinch, and carry the halves into different
   cells. This produced the only clean, symmetric division I found (C3a 170k: 60 K -> 28 + 26 K,
   two closed daughters in different membrane aggregates, both persisting and growing > 30k
   steps), plus several asymmetric or messy separations (C3a 124k, 296k; C3e 210-243k; SOUP1
   179k; PROD1 86k, 136.5k).
3. Not achieved: a robust cycle. Divisions are rare (0-3 per 100k steps per L=100 box, some
   replicates show none: C3c, PROD2), large vesicles often re-fuse or form septa (theta) that
   retract, the box fills with bilayer ribbons that tie daughters into networks, vesicles become
   catalyst-packed as K replicates (lumen N consumed), no daughter was seen to divide again, and
   catalyst-free vesicles can still gain lipid by absorbing ribbons. The official tracker
   registers none of the clean divisions (detection gaps at the neck stage).
4. Side result: a second vesicle-forming physics with a catalyst-condensate lumen and a dissolved,
   water-like nutrient (KC6, params/kc_base.ini, ckpts/KC6_100k.bin): 7-10 vesicles with ~100 K
   each from a random soup; its life runs (L1, L2) either grew too slowly or overproduced lipid
   (sponge) - not tuned further.
Most promising next steps: (a) fewer free lipids (f_lip 0.15, higher p_ld; V1/V2 running), (b)
balance K replication against N uptake (p_rep ~ p_kd + growth) so lumens stay N-rich, (c) more
statistics at L=128 (memB_final_L128 checkpoint has the same laws), (d) a time-dependent
convection pattern (stir_period) to bring more vesicles to the hyperbolic points.

### !!! PROD2 (life.ini from a random soup, seed 4): division AND a second-generation division
- Gen 1 (figs: runs/lifeB_PROD2_life/figs/cand_213000.png kfollow, micro_strip_213k-227k.png
  fluorescence): a large vesicle with 105 K (A ~325, 151 lipids, 803 N at 213k) forms an internal
  septum (217-219k: two compartments side by side), is stretched by the convection flow (221k),
  the right lobe hangs on a thin neck (223k) and is a separate closed vesicle by 225k with ~45 K;
  the left part (~60 K) stays elongated. Daughters in different membrane aggregates (ddiv:
  @231k 44 K (38 from P) + 28 K (21 from P)).
- Right daughter (khist): detected 226.5k-256.5k as one cell, A 92-103, lipids ~80 -> 98, K 41 -> 49
  (replication inside).
- Gen 2 (figs/rightdaughter_245k-289k.png): this daughter is stretched into a tube (261-264k),
  pinches into ~24 K + ~14 K compartments (267-270.5k, both detected at 270.5k, same aggregate id
  at that moment); the larger granddaughter then FUSES with a neighbouring catalyst-packed vesicle
  (277.5k, A 140, 157 K); the smaller granddaughter (10-14 K, A ~33) persists as its own detected
  cell (different aggregates) 282k-289k.
- Official pipeline on PROD2 (to 290k): 1 JA, 2 DEELS, 3 JA (e.g. track 93: 45 -> 126 lipids, lumen
  32 -> 127), 4 DEELS (1 split at 22.5k, shared membrane), 5 DEELS, 6 JA. It does not see the
  213-225k division (the dividing vesicle is not detected 215-225k: septum/neck stage).

### V1/V2 (life.ini with f_lip 0.15; V2 also p_ld 3e-5), soup seed 3, first chunk to ~146k
- Fewer vesicles (detected K-cells 3-6 in V1, 1-4 in V2), fewer ribbons.
- V1: 2 ddiv candidates; 69k -> 81.5k checked by eye (runs/lifeB_V1_flip15/figs/cand_69000.png):
  a horseshoe compartment (93 K) around an inner water vesicle; its upper arm (~18 K) separates
  from the body (~65 K) at ~79-81.5k; both are separate closed vesicles with catalysts, the
  body round and closed to >= 96k, the arm closed to >= 91k. A real (asymmetric) division.
- V2: 0 candidates.

### Tally of divisions verified by eye (two closed daughters, each with catalysts, apart >= 10k steps)
| run | laws | step | parent K -> daughters K | notes |
|---|---|---|---|---|
| C3a | membranes_final + G1 chem + cells A 2.5e-3 | 170k-174k | 60 -> ~28 + ~31 | clean, symmetric; both grow afterwards |
| C3a | same | 124k-126k | ~26 -> ~20 + ~7 | asymmetric |
| PROD2 | life.ini (cells A 3e-3) from soup seed 4 | 213k-225k | 105 -> ~45 + ~60 | septum, then flow separates; |
| PROD2 | same (2nd generation) | 267k-270.5k | ~45 -> ~24 + ~14 | granddaughters; the larger one later fuses with a neighbour |
| V1 | life.ini + f_lip 0.15, seed 3 | 79k-81.5k | 93 -> ~65 + ~18 | asymmetric |
| C3e | cells A 3e-3 | 210k-243k | 67 -> ~35 + ~17 + ~8 | messy (inside a membrane loop) |
| SOUP1, PROD1, C3a 296k | | | | borderline (daughters tied to ribbon networks or partly open) |
Rate: ~1 verified division per 100k steps per L=100 box (~5-10 vesicles) with the cells flow;
0 in the same chemistry without flow (G1a, H3) and 1 per ~60k steps in lifeA's closed system.
- PROD2 gen-2 checked with dense frames (runs/lifeB_PROD2_life/figs/gen2_262k-277k.png): the
  daughter is a long tube with catalysts at both ends (262k), it pinches (264-268k) into an upper
  (~24 K) and a lower (~12 K) closed compartment separated by medium (269-270.5k); the upper one
  fuses with a neighbouring catalyst-packed vesicle at ~271.5-273k, the lower one stays separate.
- best checkpoint for a successor: ckpts/C3a_165k.bin = runs/lifeB_C3a_rerun_to165k/ckpt.bin, a
  deterministic re-run of C3a from membranes_final to step 165000 (snapshots at 150k and 165k
  cmp-IDENTICAL to the original multi-chunk C3a run): 5k steps before the clean 170k division.
  Continue it with life_base.ini + the C3a overrides (scan/jobsCK.txt line, steps=...).

## 3b. Update of the conclusions after PROD2 / V1 (08:00 clock)
- The environmental route works in principle: in a steady convection-cell flow (stir_mode=cells,
  n=2, A 2.5-3e-3 at L=100, strain ~0.03 at the hyperbolic points, U ~0.25-0.3), with slow
  metabolism (p_syn_a 1e-4) and a uniform capped food supply, large catalyst vesicles grow by
  fusion + metabolism, get stretched at the hyperbolic points, form a neck (sometimes after an
  internal septum) and split into two closed daughters with catalysts that the flow carries into
  different cells. One daughter (PROD2) divided again ~45k steps later. This is emergent: no rule
  knows about cells; the flow acts on every bead the same way.
- It is not a robust life cycle: ~1 verified division per 100k steps per box, many attempts end in
  re-fusion or septa that retract, daughters can fuse with neighbours, membranes accumulate as
  ribbons/networks, and catalysts accumulate (lumens become catalyst-packed) because K replication
  outpaces N uptake. Catalyst-free vesicles are not prevented from gaining lipid (they absorb
  ribbons); they lose catalysts and are counted as 'dood' by the checklist, but do not shrink fast.
- Official checklist (tools/analyze.py) on the life.ini runs: 1 JA, 2 DEELS, 3 JA, 4 DEELS/NEE (no
  division with daughters in separate membranes registered - the tracker loses the dividing cell
  in the neck stage), 5 DEELS, 6 JA.

### V1 continued to 300k + FINAL life.ini (08:10 clock)
- V1 (life.ini laws, f_lip 0.15, soup seed 3) 207k -> 221.5k: the CLEANEST division found
  (runs/lifeB_V1_flip15/figs/cand_207000.png bead panels, micro_strip_207k-221k.png
  fluorescence): a vesicle with 123 K (A 179, 194 lipids) elongates in the flow (209-213k),
  becomes a dumbbell (215-217k), the neck pinches (219k) and at 221.5k there are two separate,
  closed, round vesicles with ~68 and ~56 catalysts (ddiv: 58 and 47 of them from the parent),
  in different membrane aggregates, both still closed and apart at 225k, 230k and 236k.
  Afterwards: the 56-K daughter (khist) keeps A 63-69 and lipids 84 -> 118 (231-235k), then fuses
  with another vesicle (~247k, 102 K); the 68-K daughter is mostly not detected by the team
  detector (catalyst-packed lumen), seen again at 255k (A 80, 129 lipids) and 299k.
- V1 tally: 2 verified divisions (69k->81.5k asymmetric, 207k->221.5k symmetric) in 300k steps.
  V2 (same + p_ld 3e-5): 0 candidates, fewer vesicles (1-4). PROD1 (f_lip 0.20, same seed): 0 clean.
- Official checklist on V1 (tools/analyze.py): 1 JA, 2 DEELS (228 of 1223 syntheses in a lumen,
  rho 0.69), 3 JA (7 growing cells, e.g. track 57: 54 -> 164 lipids, lumen 78 -> 219), 4 NEE,
  5 NEE, 6 JA (but catalyst-free tracks gain lipid on average, +179 per 100k steps vs -175 with
  catalysts: the per-track slope is dominated by fusions/splits, and empty vesicles absorb
  ribbons). The tracker does not register the 207k division: the parent is not detected during
  209-219k (elongated, catalyst-packed) and the daughters only intermittently afterwards.
- FINAL params: params/life.ini = V1 laws (f_lip 0.15, seed 3; stir cells n2 A 3e-3); run as-is it
  reproduces lifeB_V1_flip15 bitwise (3000 steps checked). life_fl20.ini = the f_lip 0.20 variant.
