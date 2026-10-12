# cel/notes — werklog (opruimronde 12 okt 2026, workflow "verse-kloon-fixes")

Dit bestand is het werklog van de agent die op 12 okt 2026 de kennis uit de (niet in git staande)
map `cel/runs/` naar `cel/notes/` heeft gekopieerd en de test-plumbing van de engine heeft
nagekeken. Wordt na elke stap bijgewerkt (crashveiligheid).

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
