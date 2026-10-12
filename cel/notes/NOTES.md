# cel/notes — werklog (opruimronde 12 okt 2026, workflow "verse-kloon-fixes")

Dit bestand is het werklog van de agent die op 12 okt 2026 de kennis uit de (niet in git staande)
map `cel/runs/` naar `cel/notes/` heeft gekopieerd en de test-plumbing van de engine heeft
nagekeken. Wordt na elke stap bijgewerkt (crashveiligheid).

## Inhoud van cel/notes/
- `literatuur_deling.md` — vijf routes uit de literatuur naar groei en deling, vertaald naar onze knoppen.
- `membranen/` — stap 1 van de ladder (membranen uit een soep): `teamA_TUNING.md` (memA, lineair
  lipide; `teamA_membranes.ini`, `teamA_F2_micro.png`), `teamB_TUNING.md` (memB, het gekozen
  pi-lipide; eindversie), `judge_NOTES.md` (vergelijking A/B, inbouw in de engine, ontstaan van
  `runs/membranes_final`), `figs/` (bewijsfiguren < 2 MB per team/jury).
- `leven/` — stap 2 (eten, groeien, delen): `teamA_TUNING.md` (lifeA, interne route) en
  `teamB_TUNING.md` (lifeB, omgevingsroute; eerste vanzelf ontstane delingen), allebei een
  TUSSENSTAND van 12 okt 2026 ~08:17 UTC; `figs/` (bewijsfiguren < 2 MB).
- Alle kopieën hebben bovenaan een Nederlandse kop: wat het is, waar het vandaan komt, en dat
  `runs/...` naar de ontwikkelmachine wijst (niet in git).

## Opdracht
1. `engine/tests/validate.sh` bouwt testbinaries altijd opnieuw; `git ls-files` op binaries nakijken.
2. Engine-build portabel naar Threadripper zonder AVX-512 (`-march=native` op die machine).
3. Kennis uit `cel/runs/*/TUNING.md`, `judge_src/NOTES.md`, kernfiguren → `cel/notes/`; absolute paden weg.
4. Verwijzingen in `engine/params/membranes.ini` en `engine/README.md` naar `runs/` → `notes/`.

## Voortgang
- [stap 0] Gelezen: CLAUDE.md, STARTEN.md, Makefile, validate.sh.
- [stap 1a] `git ls-files` (100 bestanden) met `file` nagelopen: geen ELF/objecten/archieven.
  Enige niet-tekst: `cel/tools/fonts/*.otf` (lettertypen, nodig voor render.py) en PNG's. OK.
- [stap 1b] `engine/Makefile`: testbinaries hebben nu `FORCE` als prerequisite (altijd opnieuw
  gebouwd, ook bij `make test`). `engine/tests/validate.sh`: `make -B` voor tests/forcetest en
  tests/molforcetest; engine/oercel via make (tijdstempel) + rooktest (L=8, 20 stappen); draait
  die niet (bv. vreemde AVX-512-build → SIGILL) dan `make -B oercel`. Print welke krachtkernel
  (AVX-512 of scalair) de build heeft.
- [stap 2a] oercel.c: AVX-512-pad zit compile-time achter `__AVX512F__ && __AVX512DQ__ &&
  __AVX512BW__ && __AVX512VL__ && !OERCEL_SCALAR` (regel 42); anders scalaire kernel. Geen
  runtime-dispatch nodig: `-march=native` op de Threadripper kiest zelf. Testbinary met
  `-march=x86-64-v3`: 0 zmm/k-registers/xmm16+ (objdump). Met native (deze Xeon): 85 zmm.
- [stap 2b] KLAAR: validate.sh in een kopie (scratchpad) met `CFLAGS=-O3 -march=x86-64-v3 ...` en
  nep-"vreemde" binaries (script dat zichzelf SIGILL stuurt, 1 uur nieuwer dan de bron):
  rooktest zag de SIGILL, engine opnieuw gebouwd; testbinaries ondanks nieuwere mtime opnieuw
  gebouwd; "scalar force kernel"; **0 FAIL** (alle 8 secties, 2 min 12 s). Engine en molforcetest
  van die build: 0 zmm/k-registerinstructies.
- [stap 2c] Kruiscompilatie forcetest voor `-march=znver2/znver3` (Threadripper 3990X/5995WX,
  geen AVX-512): compileert zonder waarschuwingen, scalaire kernel, FORCETEST PASS (hier gedraaid).
  `-march=znver4` (Threadripper 7980X, wel AVX-512): AVX-512-pad, PASS. Niet getest: een echte
  AMD-CPU en WSL2 (deze machine is een Intel Xeon met AVX-512).
- [stap 3a] Inventaris (08:15): bronnen memA/memB TUNING (eindversies), judge_src/NOTES.md,
  lifeA/lifeB TUNING (teams draaien nog: alleen lezen/kopiëren). Indeling:
  `membranen/{teamA_TUNING,teamB_TUNING,judge_NOTES}.md` + `membranen/figs/{teamA,teamB,judge,membranes_final}/`,
  `leven/{teamA_TUNING,teamB_TUNING}.md` + `leven/figs/{teamA,teamB/<run>}/`. Alleen figuren die in de
  notities als bewijs genoemd worden en < 2 MB zijn. `teamA_TUNING.md`, `teamA_membranes.ini` en
  `teamA_F2_micro.png` houden hun naam (scripts in pc/ en engine_gpu/ verwijzen ernaar).
  `teamB_TUNING_tussenstand.md` wordt verwijderd (nergens naar verwezen).
- [stap 3b] KLAAR (08:17 UTC): een eenmalig kopieerscript (in de scratchpad van de sessie; leest alleen uit runs/ en de tijdelijke map) schreef
  5 notities met kop + padcorrecties en kopieerde 36 figuren (membranen/figs 3,1 MB, leven/figs 19 MB;
  `leven/figs/teamB/C3a/div_170k_kfollow.png` is byte-gelijk aan `cel/beelden/..._controle.png`, git
  slaat dat blob één keer op). Niet gekopieerd (> 2 MB): micro/goodsell-renders van memA, memB_final_s1,
  judge, membranes_final/micro_100k.png en de micro_strip_*.png van lifeB; ook niet: de q_*.png-kijkplaatjes
  van memB en lifeB PROD1/SOUP1-kandidaten (grensgevallen). md5 van alle 5 bronnen vóór en na
  gelijk (wij schreven niets in runs/). `membranen/teamB_TUNING_tussenstand.md` verwijderd.
- [stap 4] KLAAR: `engine/params/membranes.ini` (alleen commentaar): verwijzingen naar
  notes/membranen/*; opmerking dat bitgelijkheid met memB_F01 alleen voor dezelfde build geldt
  (gemeten: native AVX-512-build vs x86-64-v3-build, membranes.ini 400 stappen: snapshot 0 gelijk,
  200 en 400 verschillend). `engine/README.md`: judge-verwijzing → notes, regel over `runs/`-paden,
  hoe je `runs/membranes_final` elders maakt, het oude scratch-pad gemarkeerd als 'pad op de
  ontwikkelmachine'.
- Niet aangepast (niet mijn bestanden, voor de hoofdsessie): `cel/pc/NOTES.md:195`
  (absoluut pad naar STARTEN.md op de ontwikkelmachine) en `cel/tools/NOTES.md:12` (absoluut
  scratchpad-pad).
  Overige treffers van de tijdelijke map in git zijn gewone tijdelijke paden die op elke machine werken.
- [stap 5] KLAAR: eindrun `engine/tests/validate.sh` op de repo (native build van deze Xeon, uitvoer in
  de scratchpad i.p.v. runs/validate): "AVX-512 force kernel", 32 PASS, **0 FAIL**, 1 min 47 s.
  tests/forcetest en tests/molforcetest zijn daarbij opnieuw gebouwd (nieuwe mtime); engine/oercel
  bleef dezelfde (md5 b727b932, tijdstempel ongewijzigd, rooktest geslaagd). Klaar.
