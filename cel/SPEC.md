# Oercel — specification

Goal: a physically grounded 2D simulation in which **living protocells emerge from a
primordial soup**, and evidence for it rendered as beautiful, realistic images.

A "living cell" in this project must satisfy all of these, each demonstrated by data:

| # | Criterion | What counts as evidence |
|---|-----------|-------------------------|
| 1 | Boundary | A closed lipid bilayer (self-assembled, not placed) enclosing an aqueous lumen |
| 2 | Metabolism | Catalysts inside the lumen convert nutrients into new membrane lipids (event log, attributed to that cell) |
| 3 | Growth | Membrane lipid count and lumen area of that cell increase over time |
| 4 | Reproduction | The cell divides into two daughters, each with its own closed membrane and catalysts |
| 5 | Heredity + selection | Catalyst variants are passed to daughters; the faster variant's share rises over time |
| 6 | Death | Cells that lose their catalysts stop growing and decay |

Nothing about cells is hard-coded. Membranes, compartments, growth and division must emerge
from bead physics + local chemistry rules. If a fallback mechanism is needed (see §6) it must
itself be local and documented honestly.

Machine: 4 cores (Xeon 2.1 GHz), 15 GB RAM, gcc 13 + OpenMP, Python 3 with numpy, scipy,
matplotlib, PIL; ffmpeg. No GPU.

## 1. Layout

```
cel/
  SPEC.md            this file
  engine/            C source, Makefile, params/*.ini, engine README
  tools/             Python analysis + rendering
  runs/<name>/       simulation output (git-ignored)
  beelden/           final images for the user
```

## 2. Physics: 2D dissipative particle dynamics (DPD)

- Units: rc = 1, kT = 1, bead mass = 1. Periodic square box of side L.
- Number density ρ = 3 (beads per unit area). Tuning box L ≈ 64–100; production L ≈ 128–160.
- Pair forces for r < rc, w(r) = 1 − r/rc:
  - conservative F^C = a_ij · w(r) · r̂
  - dissipative F^D = −γ · w(r)² · (r̂·v_ij) · r̂, γ = 4.5
  - random F^R = σ · w(r) · θ_ij / √dt · r̂, σ = 3 (σ² = 2γkT), θ_ij unit-variance, **symmetric**
    in (i, j): derive it from a counter-based hash of (seed, step, min(i,j), max(i,j)) so it is
    thread-safe and reproducible.
- Integrator: Groot–Warren modified velocity Verlet, λ = 0.65, dt = 0.03–0.04.
- Cell lists; OpenMP over cells with per-thread force buffers (or another race-free scheme).
- Bonds: harmonic ½ k_b (r − r0)², starting values k_b = 100, r0 = 0.5. Angle term on consecutive
  triplets U = k_θ (1 − cos θ) (θ = deviation from straight), starting k_θ = 10.
- Validation the engine must pass: measured kinetic temperature within ±3 % of 1; total momentum
  stays ≈ 0; pure water radial distribution looks like a DPD fluid; no bond ever exceeds 1.5.

### Bead types (uint8)

| id | name | role |
|----|------|------|
| 0 | W | water |
| 1 | H | lipid head (hydrophilic) |
| 2 | T | lipid tail (hydrophobic) |
| 3 | N | nutrient: small, can permeate membranes slowly |
| 4 | Ka | catalyst, variant a (slow) — hydrophilic, cannot cross membranes |
| 5 | Kb | catalyst, variant b (fast) — same physics as Ka, different rates |
| 6 | Z | reserved for the fallback division machinery (§6) |

Lipid = linear chain H–T–T–T (length may be tuned, e.g. H–H–T–T–T–T, if documented).

Starting repulsion matrix a_ij (tune it, document the final values): like–like 25;
W–H 15–25; W–T 80; H–T 50; N–W 25; N–H 25; N–T 35–45 (sets permeability); K–W 25; K–H 30;
K–T 120 (keeps catalysts out of the membrane); K–N 25.

## 3. Chemistry (local, stochastic, every n_chem steps, serial is fine)

All reactions conserve bead count (types change, bonds are created/removed).

1. **Lipid synthesis (metabolism)** — a catalyst K with ≥ 4 N beads within r_cat (≈ 1.2):
   with probability p_syn(variant) convert 4 of those N into a new lipid H–T–T–T. Re-place the
   4 beads as a straight chain with spacing r0 centred on their centroid (random orientation),
   give them their mean velocity, and add the bonds — never create a stretched bond.
2. **Catalyst replication (heredity)** — K with ≥ 2 N within r_cat: with probability p_rep one N
   becomes K of the same variant (with probability μ the other variant), a second N becomes W.
3. **Decay (death / turnover)** — per check: each lipid molecule with p_ld becomes 4 × W (bonds
   removed); each K with p_kd becomes W; each N with p_nd becomes W.
4. **Food supply (open system)** — maintain the nutrient fraction c_N among beads in the
   *outside medium only*: on a coarse grid (cell ≈ 1.5–2), mark cells containing T beads as
   membrane, flood-fill the non-membrane cells connected to the largest connected region =
   outside; convert random W there into N until the outside N fraction reaches c_N. Nutrients may
   enter cells only by permeating the membrane.

Each reaction is appended to the event log with step, kind, bead id(s), x, y, variant.

## 4. Initial conditions

- `init=soup`: random positions; lipid beads ≈ 8–15 % of all beads as whole randomly-oriented
  molecules, catalysts Ka ≈ 0.3–1 %, N at c_N, the rest W. Kb starts at 0 (arises by mutation).
- `init=seeded` (for testing growth/division only, never for the final claims): one pre-built
  vesicle with a few Ka inside, in a nutrient bath.
- `restart=<checkpoint>`: continue a run exactly (positions, velocities, bonds, types, RNG, step).

## 5. File formats (both engine and tools must follow exactly)

Snapshot `runs/<name>/snap_<step:010d>.bin`, little-endian:

```
char[4]  magic "OCEL"
int32    version = 1
int32    N
int32    nbonds
int64    step
float64  time
float64  L
float32  x[N]
float32  y[N]
uint8    type[N]
int32    bonds[nbonds][2]   (bead indices, i < j)
```

Plus in the run directory:
- `params.ini` — the exact parameters used (key = value, one per line, `#` comments)
- `stats.csv` — `step,time,T_kin,nW,nH,nT,nN,nKa,nKb,nZ,n_lipids,max_bond`
- `events.csv` — `step,kind,i,x,y,variant` with kind ∈ {syn, rep, mut, dlip, dK, dN, feed}
  (`feed` events may be aggregated per check: i = count)
- `ckpt.bin` — latest checkpoint, format is the engine's choice, documented in engine/README.md.

Engine CLI: `engine/oercel params.ini outdir` with every option in the ini file (including
`steps`, `snap_every`, `seed`, `threads`, `init`, `restart`).

## 6. Division

Preferred: **emergent fission** — when lipid synthesis outpaces lumen growth the membrane gets
excess area, the cell elongates and opposite sides of the bilayer touch and fuse into two closed
vesicles. Tune synthesis/replication/permeability ratios to make this happen.

Fallback (only after a genuine attempt at the preferred route, and stated honestly in every
report): a minimal FtsZ-like contractile machinery — catalysts produce Z beads from N, Z is
attracted to lipid heads, Z–Z bonds form on contact and their rest length shrinks over time,
constricting the cell until the membrane pinches. Still local rules, no cell-level logic.

## 7. Analysis (tools/)

- Read snapshots; find membranes (lipid molecules connected by tail–tail proximity < 1.0);
  rasterise each membrane on a fine grid, fill holes: an enclosed lumen with area above a
  threshold = a cell. Handle periodic boundaries correctly (unwrap clusters).
- Per cell per snapshot: id, centroid, lumen area, number of lipids, Ka/Kb inside, nutrients inside.
- Track cells over time by lumen overlap; detect divisions (one parent → two daughters that each
  pass the cell test for at least a few consecutive snapshots), deaths, and fusions; build a
  lineage tree.
- Attribute `syn`/`rep` events to the cell whose lumen contains the event position.
- Produce a life checklist (§ table at top) with numbers and the snapshot steps that prove each row.

## 8. Images (for the user — they must look beautiful and real)

The user explicitly hated the earlier neon-blob look. Aim for images a biologist would find
convincing:

1. **Fluorescence microscopy**: black background; membrane channel (H+T density) in warm
   red-magenta like an FM 4-64 membrane dye; catalysts in green (Ka) and yellow-green (Kb) like
   GFP/YFP; nutrients as a very faint blue haze. Point-spread blur (Gaussian, σ ≈ 0.6–1 bead),
   gentle shot noise, slight vignetting, a scale bar and a time stamp in a clean font. No
   blocky pixels; supersample.
2. **Molecular illustration** (David Goodsell watercolor style) of one cell, zoomed: lipid heads
   as outlined circles, tails as short strokes, catalysts as larger soft blobs, water omitted on
   a pale tinted background, soft palette, crisp outlines.
3. **Division time-lapse**: a strip of 4–6 frames following one cell through division, with
   Dutch labels (e.g. "groei", "insnoering", "deling").
4. An MP4 time-lapse of the whole dish.

All text in images is Dutch. Images go to `cel/beelden/` as PNG (≥ 1600 px wide).
