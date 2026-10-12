# tools/ - werknotities (schaalbaarheid voor de werkstation-runs)

Doel (workflow-opdracht 2026-10-12): analyse- en beeldtools robuust maken voor GPU-runs met
L = 512-2048 (0,8-12,6 miljoen deeltjes) en duizenden snapshots.

1. atomische uitvoer (tmp-bestand in dezelfde map + os.replace) voor analyze/render/video
2. cells.py/analyze.py: geheugen en tijd bij grote L; identieke resultaten bij kleine L;
   geen int16-overloop; --jobs begrensd op RAM
3. render.py micro bij L >= 1024: leesbaar en zonder geheugenexplosie; zoom snel
4. voor/na vergelijking op echte runs (kopieen, nooit in runs/ van anderen schrijven)

Werkmap voor tests: $SCRATCH/toolscale (= /tmp/claude-0/-home-user-welcome-youtube/
6ee259c0-5929-579f-9fc2-d4c5cfe2604a/scratchpad/toolscale). Originele tools staan daar in
`tools_orig/` (kopie van voor de wijzigingen) voor de voor/na-vergelijking.

## Logboek

- [start] plan gemaakt, originele tools gekopieerd naar toolscale/tools_orig.
- LET OP: de andere workflow (runs/lifeA_src/scan/mon.py, lifeB_src/scan/vstat.py, zoom.py) importeert
  tools/cells.py LIVE. Daarom ontwikkel ik in toolscale/tools_new/ en zet ik bestanden pas na
  verificatie in tools/ (atomisch: tmp + mv). API van detect() blijft gelijk (zelfde sleutels).
- Benchmark-snapshots: toolscale/tile.py legt een echte snapshot k x k naast elkaar (bindingen over
  de oorspronkelijke rand worden aan de buurkopie gekoppeld, anders ontstaan er nep-wikkelende
  membranen). Basis: runs/memA_F2 stap 100000 (L=128, 11 cellen) -> L=256/512/1024/2048.
- cells.py herschreven (tools_new): lokale rang-index i.p.v. O(N)-array per aggregaat, periodieke
  dilatatie i.p.v. EDT, wikkelende membranen op 1 kopie i.p.v. 3x3, afstand-tot-medium per lumen
  in een venster, int32/bool-roosters. Resultaat IDENTIEK (cells, label, bead_cell, summary,
  aggregates) op: tegels L=128..2048, 26 echte snapshots met wikkelende membranen (23 cellen uit
  wikkelende membranen), getegelde wikkelende gevallen (L=128..400).
  Detectie per snapshot (1 thread), voor -> na:
    L=128:  0,14 s /   94 MB  ->  0,08 s /   77 MB
    L=256:  0,56 s /  162 MB  ->  0,30 s /  102 MB
    L=512:  2,8 s  /  392 MB  ->  1,4 s  /  199 MB
    L=1024: 14,1 s / 1327 MB  ->  6,1 s  /  587 MB
    L=2048: 131 s  / 4923 MB  -> 28,5 s  / 2042 MB   (2816 cellen = 256 x 11, klopt)
  Getegeld wikkelend (memA_n01 x4, L=400): 7,6 s / 933 MB -> 1,6 s / 210 MB.
- analyze.py (tools_new): atomische uitvoer via ocio.write_json_atomic/write_atomic/save_npz_atomic
  (naam.<pid>.tmp.<ext> + os.replace + fsync; resten van gekilde processen worden bij de start
  opgeruimd), RAM-begrenzing van --jobs (schatting per proces, MemAvailable of --ram-gb),
  koppelfase parallel over blokken opeenvolgende snapshots, gebeurtenis-toewijzing (dlip 'bij cel')
  met EDT in vensters rond de gebeurtenissen i.p.v. over het hele rooster (tie-breaking identiek:
  getest op 256.000 punten met 2.021 gelijke afstanden, 0 verschillen). tracking.overlaps: geen
  overloop meer bij > 65535 labels. TOOLS_VERSION blijft 7: uitvoer en cache-formaat identiek.
- Volledige analyse oud vs nieuw (cells.json, lineage.json, checklist.json, checklist.md byte voor
  byte, + nieuwe code op de OUDE cache, + herhaalrun op eigen cache): IDENTIEK op memA_F2,
  membranes_final, memA_z02c (gebeurtenissen), synth (deling/fusie/dood), memA_F0 (deling),
  val_soup64, memA_z25s, memB_final_s1, memA_F1. (script: toolscale/cmp_analyze.sh)
- Ook IDENTIEK: lifeB_C1b_syn1e-3 (197 snapshots, 3504 syn, 1110 dlip). near_labels_at (venster-EDT)
  vergeleken met wrap_dilate_labels op alle 12,6 M pixels van 79 echte roosters: 0 verschillen.
  int32-labelpad (geforceerd via cells.INT16_LABELS) geeft dezelfde cellen; overlaps met labels
  > 65535 klopt.
- render_micro (tools_new): alleen kralen rond het beeldvlak voor zoom, kanalen een voor een,
  float32 + lean compose boven BIG_GRID, ss=1 als het beeld > 36 Mpx zou worden en de PSF >= 1 px
  is; render.py: automatische breedte (L > 1024: 2000*L/1024, max 4000), cells.json/lineage.json
  alleen laden als het nodig is, atomisch opslaan. video.py: tmp + rename, --jobs op RAM begrensd.
  goodsell: moleculen alleen uit bindingen rond het beeld (was Python-lus over alle bindingen).
  Beelden bij kleine L BIT-IDENTIEK (micro heel/--cell/--at/rand, goodsell --cell/--at, timelapse).
  Metingen (1 thread), oud -> nieuw:
    micro heel L=1024 2000px: 15,6 s / 1539 MB -> 14,9 s / 961 MB (identiek)
    micro zoom L=1024:         6,5 s /  821 MB ->  4,9 s / 568 MB (identiek)
    micro heel L=2048 2000px: 24,9 s / 2056 MB -> 19,8 s / 1494 MB (identiek)
    micro heel L=2048 4000px (nieuwe standaard): 30 s / 1493 MB, 28,8 MB PNG, goed leesbaar
    micro zoom L=2048:        13,1 s / 1346 MB ->  8,8 s / 999 MB (identiek)
- z02c_L400 (memA_z02c 30 snapshots 4x4 getegeld, met gebeurtenissen): IDENTIEK, 46,8 s / 602 MB ->
  27,0 s / 368 MB (2 processen). Lege snapshot / ongebonden lipiden: zelfde als oud.
- koppelfase: gc.freeze() voor het forken (anders kopieert een GC-ronde in een worker alle
  cel-dicts van het hoofdproces).
- tools_new/selftest.py geschreven (synthetische data: deling, 5/6 ja, kill -9-robuustheid,
  betegelde doos, alle beeldsoorten + video). Nog te draaien na de vergelijkingen.
- Getegelde volledige analyses (2 processen) IDENTIEK: F2_L512 (51 snapshots) 103,6 s / 781 MB ->
  54,9 s / 395 MB; F2_L1024 (12 snapshots) 117 s / 2,7 GB -> 67 s / 1,04 GB.
- Detectie IDENTIEK op tegels van soep (stap 0, 85.312 aggregaten), vormingsfase (stap 20000/30000),
  sponsnetwerken (memA_m06 x4, memA_n05 x6: reuzennetwerk van 37.260 lipiden, 36 cellen uit een
  wikkelend membraan: 17,7 s / 2,0 GB -> 3,5 s / 383 MB).
- video.py op F2_L1024: gedecodeerde frames IDENTIEK aan oud (32,7 s / 926 MB -> 29,1 s / 847 MB).
- selftest.py: 18/18 PASS (ook geinstalleerd). kill_test (10 kills analyze, renders, video op
  z02c_L400): nooit afgekapt, eindresultaat identiek. pc/tests/test_thinning.sh (uitvoer in
  scratch, met de geinstalleerde tools): 13/13 PASS.
- GEINSTALLEERD in tools/ (05:32, per bestand tmp + mv): ocio, tracking, cells, render_micro,
  render_goodsell, render, video, analyze, debug_cells, selftest, README. checklist.py,
  render_timelapse.py, style.py, make_synthetic.py ongewijzigd.

## Niet getest / open punten (eerlijk)
- Geen echte GPU-snapshots van L=512-2048: alle grote-L metingen zijn op getegelde echte
  snapshots (periodiek geldig, maar herhalend). Echte grote dozen kunnen andere structuren hebben
  (bv. meer wikkelende netwerken); die paden zijn wel getest op echte sponsfasen.
- Geheugenschattingen voor --jobs zijn gefit op deze machine (1 thread); op de Threadripper even
  controleren met `analyze.py RUN --jobs 64` (er verschijnt een regel als het wordt begrensd).
- Het hoofdproces van analyze.py houdt alle celwaarnemingen in het geheugen (~2 KB per cel per
  snapshot); bij L=2048 met duizenden snapshots kan dat meerdere GB worden (waarschuwing ingebouwd,
  --every helpt). cells.json wordt dan ook groot (~0,4 KB per waarneming) en render.py --cell/
  goodsell/timelapse lezen het helemaal in.
- pc/longrun.py geeft altijd --width 2000 mee aan render.py; daardoor krijgt een L=2048-schaal
  niet de automatische 4000 px (wel leesbaar, maar kleiner). Mag ik pc/ niet aanpassen: voorstel
  voor de hoofdsessie om --width alleen mee te geven als de gebruiker het zet.
- pc/tests/test_kill_stress.sh niet gedraaid (6-10 min, zware engine-delen); eigen kill-tests wel.
- Op WSL2 zelf niet getest (geen WSL hier); fsync + os.replace zijn standaard POSIX/ext4.

## Onafhankelijke review (2026-10-12, tweede agent) - werkmap scratchpad/review_tools (NOTES.md daar)
- Detectie oud vs nieuw IDENTIEK op: 34 adversariale scenes x 3 seeds (rand/hoek, lumens rond 16, vesikel
  > L/2, vesikel die zijn eigen periodieke beeld raakt, rakende vesikels ook over de rand, genest,
  wikkelende strepen/kruis/roosters, diagonaal, buis langer dan L, niet-gehele L, L=12-16), 80 willekeurige
  schuim-scenes (20 met geforceerd int32-pad), lege dozen (N=0, water, ongebonden lipiden, soep),
  2 x ~1300 echte snapshots (3 per run, alle 443 runs), getegelde sponzen L=400/600/1000.
- analyze.py byte voor byte oud vs nieuw op 9 andere echte runs, 3 nieuwe synthetische runs, getegelde
  z02c_L400 (gebeurtenissen) en een run met lege snapshots: IDENTIEK.  near_labels_at: 2,1 M queries met
  veel exacte gelijke afstanden: 0 verschillen.
- kill -9: 30x procesgroep, 15x alleen hoofdproces, 25x midden in (vertraagde) json-writes, 8x video:
  nooit een afgekapt of afwijkend eindbestand.
- GEVONDEN + GEREPAREERD: de RAM-schatting voor --jobs was te laag voor een doosvullend sponsnetwerk
  (memA_n05 x20, L=2000: piek 3,49 GB, schatting 2,6 GB).  cells.py geeft nu tijdelijke data eerder vrij
  (_unwrap_tree: BFS-graaf en Python-lijsten weg voor de wraps-test, die in blokken van 512k randen;
  _holes_torus: pixel-lijsten per gat vrijgeven; bincount in blokken) -> 2,67 GB (L=1000: 939 -> 734 MB),
  resultaten identiek.  detect_mem_estimate = 1,25 x (90 MB + 80 B/kraal + 26 B/px) (L=2048: 3,55 GB).
  Vesikeldoos L=2048 (F2 x16) gemeten: 1,44 GB.
- Klein: video.py en debug_cells.py doen nu ook fsync voor de rename; debug_cells ruimt tmp op bij een fout.
