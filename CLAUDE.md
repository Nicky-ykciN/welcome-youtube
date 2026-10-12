# Oercel — instructies voor Claude

## De gebruiker
- Praat **Nederlands**.
- Wil **zelf niets doen**: jij draait, bewaakt en repareert alles. Vraag alleen iets als het echt hun beslissing is.
- Wil **resultaten zien als afbeeldingen** (PNG, eventueel MP4). **Geen HTML-pagina's of artifacts** — dat is expliciet afgewezen.
- Houdt niet van snelle speelgoedversies. Neem de tijd, laat simulaties echt lang draaien, controleer je werk.
- Wees eerlijk: zeg wat wel en niet werkt. Nooit iets nabootsen of als resultaat presenteren wat niet echt uit de simulatie kwam.

## Het doel
Echt **emergent leven** in een simulatie, geïnspireerd door een tweet van Fraser Price
(neurale netwerken in deeltjes in een thermodynamische CA → meercellig leven door natuurlijke
selectie). Wij gaan een niveau dieper: de cel zelf moet uit moleculen ontstaan.

De ladder:
1. ✅ Moleculen → cellen: membranen ontstaan vanzelf uit een willekeurige soep en sluiten
   enzymen in (zie `cel/notes/membranen/`).
2. ⏳ Cellen gaan leven: eten, groeien, vanzelf delen, natuurlijke selectie.
3. Rijke erfelijkheid: een genoommolecuul dat zichzelf kopieert via een mal (RNA-achtig),
   waarvan de volgorde bepaalt wat het enzym kan.
4. Brug naar meercelligheid (Frasers niveau): wat een cel fysiek kan wordt gemeten in de
   moleculaire wereld; daarop een wereld waarin elk deeltje één cel is met een evoluerend
   regelnetwerk. **De gebruiker moet akkoord geven voor deze stap** (het is grofkorrelen).

## Stand van zaken (overdracht vanuit de cloudsessie, 12 okt 2026)
- **Membranen**: opgelost. `cel/engine/params/membranes.ini` (gebonden twee-staart 'pi'-lipide +
  voedsel/water twee-fasensysteem) geeft vanuit soep 9–14 gesloten cellen met enzymen per L=100.
- **Deling**: voor het eerst vanzelf gezien (levensteam B), maar zeldzaam (~1 nette deling per
  100k stappen per bak), nog geen tweede generatie, en `tools/analyze.py` registreert ze niet
  (de cel verdwijnt uit de detectie tijdens de halsfase). Beelden: `cel/beelden/`, notities en
  bewijs: `cel/notes/leven/` (lees `teamB_TUNING.md` en `teamA_TUNING.md` eerst).
- De delingen komen uit de omgevingswet **convectiecellen** (`stir_mode=cells`, plus
  `stir_period/stir_duty`, `feed_period/feed_duty`). Die zit **alleen** in
  `cel/notes/leven/engine_teamB/oercel.c`, nog niet in `cel/engine/` en niet in `cel/engine_gpu/`.
  De beste parameters: `cel/notes/leven/params_teamB/life.ini` (run V1, vanuit soep, seed 3).

## Open punten (in deze volgorde)
1. **Engine bijwerken**: de stir/feed-features uit `notes/leven/engine_teamB/oercel.c` netjes in
   `cel/engine/oercel.c` zetten (diff t.o.v. de huidige engine; `tests/validate.sh` moet slagen),
   en dezelfde features in `cel/engine_gpu/oercel_gpu.cu` (pariteit; `selftest_gpu.sh`).
   Dan `life.ini` naar `cel/engine/params/production.ini` (plan.txt gebruikt die automatisch voor
   een nieuwe run) en een convectiecel-variant toevoegen aan `cel/pc/voorbeelden/leven_scan.txt`.
2. **Tracker**: `tools/analyze.py` moet delingen in stromend water herkennen (cel volgen via zijn
   enzym-ID's door de halsfase heen; team B heeft hiervoor `scan/kfollow.py`/`khist.py`-ideeën,
   zie de TUNING-notities).
3. **Herstart-bestendig maken** (Windows-taakplanner bij inloggen, `start.sh --automatisch`,
   WSL wakker houden): half af, nog niet getest. Het halve werk staat als patch in
   `cel/notes/onaf/herstart_bestendig_WIP.patch` (+ `autostart_WIP.sh`). `cel/pc/` zelf staat op
   de laatst volledig geteste versie (test_start.sh 138/138).
4. Kleinere punten uit de proefrit: race in `cel/pc/tests/test_sweep_kill.sh` (pid opnieuw lezen
   vlak voor kill), `test_thinning.sh` zelfstandig maken, kop van
   `cel/pc/voorbeelden/lipide_architectuur_memB.txt` is verouderd, `longrun.py --forceer-engine`
   van GPU naar CPU moet het checkpoint eerst omzetten met `cel/engine_gpu/ckpt_to_cpu.py`,
   `cel/engine/oercel.c` zou stats/events/snapshots moeten fsyncen bij een checkpoint (WSL-shutdown).
5. Daarna het eigenlijke doel: deling robuust en herhaald krijgen (generaties), en kijken of de
   snelle enzymvariant (Kb) de langzame verdringt = natuurlijke selectie.

## De emergentieregel (niet onderhandelbaar)
Staat in `cel/SPEC.md` §0. Kort: alleen natuurwetten (krachten, bindingen binnen moleculen,
lokale reacties tussen moleculen die elkaar raken, omgeving die elk deeltje gelijk behandelt).
**Niets neerzetten** (start is altijd een willekeurige soep), **geen regel die weet wat een
cel/membraan/binnen/buiten is**, **geen ingebouwde deling**. De gebruiker zei letterlijk:
"Alles wat je zelf neerzet weggooien. Ik wil emergente eigenschappen en geen geengineer!"
Als iets niet vanzelf ontstaat: eerlijk melden.

## Waar alles staat
- `cel/SPEC.md` — specificatie, bestandsformaten (§5), levenscriteria.
- `cel/engine/` — referentie-engine (C + OpenMP), `README.md` met alle parameters.
- `cel/engine_gpu/` — CUDA-versie voor de RTX 8000 (zelfde CLI en uitvoer). Eerst
  `selftest_gpu.sh` draaien.
- `cel/tools/` — analyse (`analyze.py`: cellen, delingen, stamboom, levens-checklist) en
  beelden (`render.py --kind micro|goodsell|timelapse`, `video.py`).
- `cel/pc/` — installatie (`setup_wsl.sh`), parameter-sweeps over 64 kernen (`sweep.py`),
  lange runs met automatisch hervatten (`longrun.py`), overzicht (`status.py`).
- `cel/notes/` — wat eerdere teams geleerd hebben (lees dit voor je gaat afstemmen).
  Voor groei en deling: `cel/notes/literatuur_deling.md` (vijf routes uit de literatuur,
  vertaald naar onze knoppen).
- `cel/runs/` — simulatie-uitvoer (niet in git).
- `cel/beelden/` — afbeeldingen voor de gebruiker.
- `index.html` (in de root) — een eerdere speelgoedversie; de gebruiker vond die lelijk. Niet verder gebruiken.

## Toestemmingen
`.claude/settings.json` staat een smalle lijst commando's toe zonder vragen (de scripts in
`cel/pc/` en `cel/tools/`, de engines, `make -C cel/...`, git op deze branch, alleen-lezen
commando's) en verbiedt o.a. `sudo` en force-push. Gebruik die vaste vormen (vanuit de
repo-root, bv. `python3 cel/pc/status.py --kort`), dan hoeft de gebruiker niets goed te keuren.
Breid de lijst niet zelf uit; vraag het de gebruiker als iets anders echt nodig is.

## Werkwijze op deze pc
- Hardware: AMD Threadripper 64 kernen, NVIDIA Quadro RTX 8000 (48 GB, sm_75), WSL2.
- Grote runs op de GPU; de 64 kernen voor veel kleine runs tegelijk (sweeps, replicaties).
- Houd notities bij in `cel/notes/` en commit + push regelmatig naar de branch
  `claude/leuk-om-na-te-maken-cgzea9`, zodat niets verloren gaat. Alleen de hoofdsessie
  doet git; sub-agents en workflow-agents gebruiken geen git tenzij hun opdracht dat zegt.
- Laat de gebruiker af en toe beelden zien van echte tussenresultaten, met een eerlijke uitleg.
