# Oercel tools: analysis and images

Python 3 with numpy, scipy, matplotlib, pandas, PIL and ffmpeg. Everything works on the file
formats of SPEC §5. Fonts: Inter (SIL OFL) in `tools/fonts`, with DejaVu as fallback.

## Commands

```bash
python3 tools/analyze.py runs/<name>                      # cells.json lineage.json checklist.md checklist.json
python3 tools/render.py  runs/<name> --kind micro         # fluorescence micrograph, whole dish (last snapshot)
python3 tools/render.py  runs/<name> --kind micro --cell 7 --step 120000    # zoom on track 7
python3 tools/render.py  runs/<name> --kind goodsell [--cell 7] [--step S]  # watercolour molecular illustration
python3 tools/render.py  runs/<name> --kind timelapse [--cell 7] [--panels 5] --width 3600
python3 tools/video.py   runs/<name> --out beelden/<name>.mp4 [--fps 12 --width 1080 --interp 2]
python3 tools/make_synthetic.py runs/synth                # FAKE test run (flagged synthetic = 1)
python3 tools/debug_cells.py runs/<name> --step S --out /tmp/d.png   # beads + detected lumens
```

* `--cell` always means a **track id** ("spoor") from `lineage.json`. Track ids stay the same over
  time; the per-snapshot cell indices do not.
* By default images go to `cel/beelden/<run>_<kind>_<...>.png`. Synthetic runs write to
  `runs/<name>/beelden_test/` instead and carry a "SYNTHETISCHE TESTDATA" label.
* `analyze.py` caches per-snapshot detection in `runs/<name>/analysis_cache/`, so re-running it on a
  growing run only processes new snapshots. Detection uses 2 processes (`--jobs`). Measured cost:
  about 25 ms per snapshot at N = 28k beads.
* Scale bars assume 1 r_c ≈ 1 nm (a bilayer in this model is about 4 r_c thick; a real one is
  4-5 nm). Change this with `--rc-nm`. Time is shown in DPD units τ, and the step number is
  always shown too.

## Cell detection (SPEC §7) - `cells.py`

1. Lipid molecules are the connected components of bonds between H/T beads, so any length works
   (`H-T-T-T`, `H-H-T-T-T-T`, ...).
2. A membrane is a set of molecules joined by tail-tail contacts (T-T < 1.0, periodic KD-tree).
3. Each membrane with at least 12 lipids is unwrapped across the periodic boundaries by a
   breadth-first walk over its bonds and tail contacts. If the walk is inconsistent, the membrane
   wraps the torus. It is then rasterised on the full periodic grid with 3x3 tiling, where
   "enclosed" means "does not reach the edge of the tiling" (contractible).
4. The membrane's H+T beads are stamped as disks (r = 0.75) on a 0.25 grid. Holes are solvent
   regions that are not connected to the outside (4-connectivity).
5. A hole counts as a **cell** only if all of these hold:
   * area ≥ 10 r_c²;
   * it is aqueous (W+N+K beads ≥ 0.3·ρ·area);
   * **exposure ≥ 0.5**: at least half of the lumen boundary lies within one membrane thickness
     (2·lipid length·r0 + 4) of the bulk medium. The bulk medium is the largest periodic solvent
     region, the same idea as the engine's food flood fill. This rejects water pockets buried in a
     lipid matrix, which were seen in a real `soup_small` run, and also a "lumen" that is itself
     the bulk.
6. Wall lipids are the molecules of that membrane whose nearest bead is within one membrane
   thickness of the lumen. When one membrane encloses several lumens, each lipid goes to its
   nearest lumen. Contents (Ka, Kb, N, W, Z) are counted on a periodic label grid; nested lumens
   overwrite outer ones.
7. Per cell the tools also report `inner_frac`, the share of wall heads facing the lumen
   (a bilayer gives about 0.4-0.47), `wall` (median wall thickness), aspect ratio, solidity
   (constriction), and centroid (periodic-safe).

## Tracking, events, lineage - `tracking.py`

* Links come from pixel overlap of lumens in consecutive snapshots (overlap / smaller area ≥ 0.25),
  with a centroid fallback for cells that moved further than their own size.
* 1→2 is a **division** ("deling") only if both daughters persist for ≥ 3 snapshots, stay
  separate (no fusing back), and miss at most one snapshot. Otherwise the event is an
  "afsplitsing" fragment and the parent track continues. 2→1 is a **fusion**, unless one partner
  is a fragment. n→m is a greedy rearrangement.
* A cell that is missing for up to 2 snapshots is bridged (`gaps` in the track). A track without a
  successor ends as "verdwenen" (death candidate). A track without a predecessor is "nieuw
  gevormd": a vesicle that closed by itself.
* Divisions too close to the end of the run to confirm are marked `confirmed: false`.

## Event attribution and evidence

* `syn`, `rep`, `mut` and `dK` events go to the cell whose lumen contains (x, y) in the nearest
  snapshot. `dlip` events go to the nearest lumen within 4.5.
* **New lipids**: snapshots are in global-id order, so a bead that was N in snapshot k−1 and is
  H/T in snapshot k is a newly synthesised lipid. The analysis counts how many of those sit in a
  cell wall at snapshot k, per cell. This proves "nutrients → membrane lipids of this cell"
  independently of the event log. Synthetic data shuffles ids (`stable_ids = 0`), so the check is
  skipped there.

## Life checklist - `checklist.py`

Each SPEC criterion gets "ja", "deels" or "nee", with the numbers and steps behind it. The
thresholds are explicit:

1. Boundary: a cell formed by itself (start "nieuw gevormd", persisting ≥ 3 snapshots), init = soup,
   and ≥ 80 % of observations with a bilayer-like `inner_frac`.
2. Metabolism: cells with ≥ 5 attributed syntheses, and ≥ 25 % of new lipids found in cell walls.
   Also reported: Spearman correlation per cell between syntheses and new wall lipids.
3. Growth: a track whose lipid count and lumen area both rise significantly (linear fit p < 0.05)
   with ≥ 15 % more lipids.
4. Reproduction: a confirmed division in which both daughters sit in different membrane aggregates
   (each has its own closed membrane) and contain catalysts. The report states the mechanism:
   "emergent", or "terugvalmechanisme (Z)" if Z beads exist.
5. Heredity + selection: catalysts in both daughters, plus the Kb share among catalysts inside
   cells rising over time (Kendall τ > 0, p < 0.05, Δ ≥ 0.05).
6. Death: a cell that lost all catalysts, then stopped growing (slope ≤ 0 or not significant) and
   decayed (vanished, or ≥ 10 % fewer lipids). Also reported: mean lipid growth with and without
   catalysts.

Caveats such as synthetic data, a seeded init, or the fallback division are written at the top of
`checklist.md`.

## Images (SPEC §8)

* **micro** (`render_micro.py`): beads are deposited (bilinear) and convolved by FFT with a PSF made
  of a σ = 0.65 core plus a 7 % out-of-focus halo. This is exact for the periodic whole-box view.
  * Membrane dye (FM 4-64, crimson): brightness depends on the hydrophobic environment
    (number of tail neighbours). It is strongest at the chain ends, i.e. the bilayer midplane,
    which gives a crisp membrane line. Free lipids are dim.
  * GFP (Ka) and YFP (Kb) puncta each have a stochastic brightness that is fixed per bead id, so
    it is stable in the video.
  * Nutrients show as a faint blue haze.
  * Detector model: Poisson shot noise per channel, read noise, dark offset, vignetting, soft knee,
    gamma 1/1.45.
  * Normalisation: the membrane percentile for single images; one fixed value for videos and
    time-lapses, so there is no flicker.
* **goodsell** (`render_goodsell.py`): every molecule is drawn at its simulated position; water is
  left out.
  * Lipids: ink-outlined heads, a tail band with one stroke per tail.
  * Catalysts: lobed protein blobs with a single union outline; the shape is fixed per bead id.
  * Nutrients: small muted circles.
  * Washes: warm inside the lumen (from detection), cool outside. Pigment density varies, with
    pooling at the edges, paper granulation and fibres, and a deckled painted edge.
  * Drawn at 3x and downsampled with Lanczos; the legend and scale bar sit in a paper band below.
* **timelapse** (`render_timelapse.py`): picks the best confirmed division. Panels are chosen from
  measured shape:
  * groei: an early frame;
  * strekking: aspect ratio ≥ 1.35;
  * insnoering: lowest solidity before the split;
  * deling: the first frame with daughters;
  * twee dochtercellen: later frames.
  All panels share one exposure. Arrowheads mark the tracked cell(s), and a time axis runs below.
* **video** (`video.py`): whole-dish micrographs, rendered with 2 processes and piped into ffmpeg
  (H.264, yuv420p, crf 18). Camera noise is new each frame, molecules keep their dye load, and
  `--interp k` adds cross-fades.

## Known limitations

* An "exposure" test is needed because 2D DPD soups readily form inverted or sponge phases. Cells
  pressed into a crowded membrane network may be missed for a few frames; gap bridging covers
  short dropouts.
* The fluorescence look is a stylised physical model, not a real microscope. The real resolution
  limit (~200 nm) is far larger than these structures.
* Tested on synthetic data and on small engine runs (`init = seeded` L = 48, `soup_small` L = 64).
  Large production runs (L = 128-160) have not been tested yet.
