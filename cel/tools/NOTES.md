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
