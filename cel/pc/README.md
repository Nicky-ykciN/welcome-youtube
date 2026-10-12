# cel/pc — Oercel op de werkplek (Windows + WSL2 + NVIDIA-GPU)

Alles wat nodig is om Oercel op de Threadripper-werkplek te installeren en te laten draaien,
zonder handwerk. De scripts starten, bewaken en hervatten alleen de engine; ze veranderen niets
aan de natuurwetten van de simulatie (SPEC §0). Analyse-uitkomsten worden alleen gebruikt om te
beslissen welke *bestanden* bewaard blijven, nooit om de simulatie bij te sturen.

| bestand | wat |
|---|---|
| `setup_wsl.sh` | installatie in WSL2: pakketten, Python, CUDA-toolkit, engines bouwen, tests |
| `sweep.py` | veel kleine runs tegelijk (parametervarianten × seeds) over alle kernen, hervatbaar, met ranglijst |
| `longrun.py` | één lange productierun (GPU, anders CPU) met checkpoints, analyse, beelden en begrensd schijfgebruik |
| `status.py` | overzicht van alle sweeps en lange runs; `--hervat` start na een herstart alles weer |
| `env.sh` | `source cel/pc/env.sh`: venv en CUDA in `PATH` (alleen nodig als setup een venv moest maken) |
| `voorbeelden/` | jobbestanden voor `sweep.py` |
| `tests/` | de tests waarmee deze scripts zijn gecontroleerd (zie onderaan) |
| `pclib.py`, `cuda_check.cu` | gedeelde hulpfuncties; kleine CUDA-test voor setup |

## 1. Eenmalig: installeren

In Windows hoeft alleen de gewone **NVIDIA-driver voor Windows** geïnstalleerd te zijn (Quadro RTX
8000). In Ubuntu (WSL2) komt **nooit** een NVIDIA-driver; de Windows-driver levert de GPU.

In een Ubuntu-terminal (WSL2):

```bash
cd ~                                   # NIET onder /mnt/c: daar is alles ~10x trager
git clone -b <branch> <github-url>     # de repo
bash ~/<repo>/cel/pc/setup_wsl.sh      # vraagt één keer je wachtwoord (sudo); 20-50 min*
cd ~/<repo> && claude remote-control
```

\* De CUDA-toolkit is een download van enkele GB en de volledige GPU-zelftest duurt 10-20 minuten;
met `--snel` wordt dat `selftest_gpu.sh --quick` en vervalt validate.sh.

`setup_wsl.sh` is veilig om opnieuw te draaien: elke stap die al gedaan is wordt overgeslagen, en een
eerdere poging die halverwege werd afgebroken wordt afgemaakt (onderbroken `dpkg` → `dpkg --configure -a`,
een half geïnstalleerde CUDA-toolkit wordt aangevuld, een kapotte venv gerepareerd). apt wacht tot 10
minuten op de dpkg-vergrendeling (vlak na de eerste start van WSL draait vaak `unattended-upgrades`).
Het doet:

1. **Controle**: draait het in WSL2 (niet WSL1)? Staat de repo onder `/mnt/c` (traag → het zegt hoe
   je hem naar `~` verplaatst)? Ubuntu-versie, kernen, geheugen, vrije schijf.
2. **apt**: `build-essential`, `python3` met numpy/scipy/matplotlib/pandas/pillow/yaml, `ffmpeg`,
   lettertypen, `git`. Lukt de systeem-Python niet, dan maakt het een venv in `cel/pc/.venv`
   (en laat `~/.bashrc` die laden via `env.sh`).
3. **CUDA**: eerst `nvidia-smi` (moet werken, anders: Windows-driver installeren/bijwerken en in
   PowerShell `wsl --shutdown`). Dan alleen het pakket `cuda-toolkit-X-Y` uit NVIDIA's officiële
   **WSL-Ubuntu**-repository:
   `https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb`
   (`dpkg -i`, `apt-get update`, `apt-get install cuda-toolkit-X-Y`). X-Y is de hoogste versie in die
   repository die de Windows-driver aankan (“CUDA Version” in `nvidia-smi`); met `--cuda-versie 12-6`
   kies je zelf. Lukt die niet, dan de volgende lagere versie (max. 3 pogingen), en per versie als
   laatste redmiddel alleen compiler + runtime (`cuda-nvcc-X-Y cuda-cudart-dev-X-Y cuda-cccl-X-Y`, genoeg
   voor `oercel_gpu`). Op Ubuntu 20.04 alleen CUDA 12.x of ouder (CUDA 13 ondersteunt 20.04 niet).
   Is de WSL-repository onbereikbaar, dan valt het terug op NVIDIA's gewone repository voor de
   gedetecteerde Ubuntu-versie (`repos/ubuntu2404/...`), ook dan alleen de toolkit.
   Een apt-pin (`/etc/apt/preferences.d/oercel-geen-linux-nvidia-driver`) blokkeert alle
   Linux-driverpakketten (`cuda-drivers`, `nvidia-driver-*`, `libnvidia-compute-*`, `nvidia-utils-*`, …),
   dus ook per ongeluk kan er geen Linux-driver in komen; staat er al een, dan meldt het script dat
   met het verwijdercommando. De metapakketten `cuda`, `cuda-12`/`cuda-13` en `cuda-drivers` worden
   nooit gebruikt. `nvcc` komt in `PATH` via `/etc/profile.d/oercel-cuda.sh`. Een klein testprogramma
   (`cuda_check.cu`, gecompileerd voor sm_75) draait op de GPU; weigert `nvcc` de gcc-versie, dan
   probeert het automatisch een oudere `g++-N` (en bouwt `engine_gpu` met `CCBIN=g++-N`).
   Lukt de systeem-installatie niet (geen root, downloadfout), dan valt het terug op
   `engine_gpu/setup_wsl.sh` van de GPU-engine, die `nvcc` **zonder root** uit NVIDIA's
   redistributable-archieven in `engine_gpu/.cuda` zet.
4. **Bouwen**: `make -C engine` (CPU, `-march=native`) en `make -C engine_gpu` (als die map er is).
   De Threadripper heeft mogelijk geen AVX-512 (Zen 2/3); dan gebruikt de engine automatisch zijn
   geteste scalaire kernel.
5. **Tests**: `engine/tests/validate.sh` (29 controles), `engine_gpu/selftest_gpu.sh` (als die er
   is), een korte GPU-proefrun, een proefrun van soep → `tools/analyze.py` → `tools/render.py`.
6. **Samenvatting** met per onderdeel OK / WAARSCHUWING / FOUT / OVERGESLAGEN. Log:
   `cel/runs/_setup/setup_<tijd>.log`. De uitslag van de GPU-zelftest wordt per build onthouden in
   `cel/pc/_build/gpu_selftest.json`: faalde de zelftest, dan gebruikt `longrun.py` de CPU-engine.

Opties: `--geen-apt`, `--geen-cuda`, `--cuda-versie X-Y`, `--snel` (zonder validate.sh, GPU-zelftest `--quick`),
`--geen-tests`, `--droog` (alleen tonen wat er met root zou gebeuren).

**sudo**: apt en CUDA hebben root nodig. Claude Code kan geen wachtwoord typen. Draai het script
daarom één keer zelf (zie boven), of vanuit Windows PowerShell als root:
`wsl -u root bash /home/<gebruiker>/<repo>/cel/pc/setup_wsl.sh` (bestanden in de repo blijven dan
van jouw gebruiker; ook de mappen die het script aanmaakt, zoals `cel/runs/`). Zonder root doet het alles
wat wel kan en zegt het precies wat nog ontbreekt.

## 2. Voor Claude: dagelijks gebruik

Belangrijk: een Bash-commando van Claude Code mag maximaal 10 minuten duren. Start runs daarom
altijd met `--achtergrond`; ze draaien dan los van de sessie door (eigen proces­groep, log in de
run-map) en `status.py` laat zien hoe het gaat.

```bash
python3 cel/pc/status.py                     # alles in één scherm (Nederlands)
python3 cel/pc/status.py NAAM                # één run/sweep met volledige checklist en beelden
python3 cel/pc/status.py --hervat            # na een herstart: alles wat onderbroken was weer starten
```

`--hervat` start alles wat **onderbroken** is (gedood, stroomstoring, of gestopt door het afsluiten van
WSL/Windows). Wat bewust met `--stop` is gestopt blijft stil; `status.py` toont het onder "BEWUST
GESTOPT" met het commando om het toch te hervatten. `status.py` toont ook hoeveel engine-threads er
draaien t.o.v. het aantal CPU's; `sweep.py` en `longrun.py` waarschuwen bij de start als de machine
daarmee overboekt raakt.

Instellingen van een run of sweep die al draait kunnen niet veranderen: zo'n commando (bijv.
`longrun.py NAAM --steps ...`) zegt `NIET TOEGEPAST` en geeft exit-code 1; eerst `--stop`, dan opnieuw.

Alle scripts werken vanuit elke map; paden in jobbestanden en `--ini` mogen relatief aan `cel/` zijn.

### 2a. `sweep.py` — veel varianten tegelijk op de 64 kernen

```bash
python3 cel/pc/sweep.py cel/pc/voorbeelden/membraan_seeds.txt --achtergrond
python3 cel/pc/sweep.py JOBBESTAND --proef          # alleen joblijst + engine-commando tonen
python3 cel/pc/sweep.py --hervat NAAM --achtergrond  # verder na crash/reboot (of hetzelfde startcommando)
python3 cel/pc/sweep.py --stop NAAM                 # netjes stoppen; jobs schrijven een checkpoint
python3 cel/pc/sweep.py --samenvatting NAAM         # ranglijst opnieuw maken
python3 cel/pc/sweep.py JOBBESTAND --heranalyse     # alle klare jobs opnieuw analyseren (na tools-update)
```

Jobbestand (tekst; `.json` of `.yaml` met dezelfde sleutels kan ook, zie `voorbeelden/varianten.json`):

```
naam  = chemie_scan                            # map runs/chemie_scan/ (standaard: bestandsnaam)
basis = notes/membranen/teamA_membranes.ini    # basis-ini (relatief aan cel/ of aan het jobbestand)
seeds = 1-4                                    # of "1 2 3 4": elke variant één keer per seed
steps = 300000                                 # elke andere 'sleutel = waarde' hier geldt voor ALLE jobs
zet   = chem=1 events=1                        # idem, meerdere op één regel
raster p_syn_a = 2e-5 5e-5 1e-4                # raster: elke combinatie wordt een variant
raster p_feed  = 3e-5 1e-4
[stijf]                                        # expliciete variant (wordt met het raster gecombineerd)
k_angle = 25
```

- Volgorde van overschrijven: basis-ini < algemene sleutels < variant < raster < seed.
- `threads`, `walltime`, `restart` en `ckpt_keep` regelt `sweep.py` zelf.
- Elke sleutel wordt vooraf gecontroleerd tegen `engine --params`: een tikfout of een sleutel die
  de engine niet kent (bv. `lip_arch` van team B) stopt de sweep vóór de start, met uitleg. Een
  andere engine met dezelfde CLI: `--engine pad/naar/binary`.
- Parallel: standaard `--threads 2` per job en `--jobs (logische CPU's − 2) / 2` tegelijk
  (128 threads op de Threadripper met SMT → 63 jobs). Analyses van klare jobs nemen ook een plek.
  Een sweep is gemaakt om de hele machine te vullen: draai er één tegelijk (of geef `--jobs` mee), en
  naast een lange run op de **CPU** (32 threads) minder jobs, bijv. `--jobs 47`. Met `--engine gpu`
  is de standaard 4 jobs tegelijk (ze delen één GPU).
- Elke job: `runs/<sweep>/<job>/` met de normale engine-uitvoer, in chunks van `--chunk-min`
  (standaard 60) minuten met checkpoints. Na crash, `kill -9` of reboot gaat elke job verder vanaf zijn
  laatste checkpoint; het resultaat is bit-voor-bit gelijk aan een ononderbroken run (getest).
- Een job die vastloopt wordt tot 4 keer opnieuw geprobeerd (met wachttijd), daarna `fout`; een
  nieuwe start van de sweep geeft mislukte jobs opnieuw een kans. Checkpoints worden nooit gewist; een
  checkpoint wordt alleen als onbruikbaar overgeslagen als de engine zelf zegt dat het checkpoint niet
  te lezen is (niet bij `kill -9`, een volle schijf of een ontbrekende GPU).
- Schijf bijna vol (< 10 GB): lopende jobs stoppen netjes met een checkpoint (telt niet als crash) en
  er starten geen nieuwe chunks tot er weer ruimte is.
- Klare jobs worden geanalyseerd met `tools/analyze.py`. Uitvoer in `runs/<sweep>/`:
  - `SAMENVATTING.md`: ranglijst per variant (gemiddeld over de seeds) en per job: checklist 1–6
    (J/d/-), aantal ja/deels, delingen (bevestigd), gesloten cellen nu/max, cellen met katalysatoren,
    max generatie; plus de checklist van de beste job;
  - `samenvatting.csv` (zelfde cijfers, machineleesbaar), `STATUS.md` (voortgang),
    `pc_sweep.json` (toestand), `pc_sweep.log`, kopieën van jobbestand en basis-ini.
- Toevoegen: hetzelfde jobbestand met extra varianten/seeds opnieuw starten voegt alleen de nieuwe
  jobs toe. Een bestaande job met andere parameters, of een gewijzigde basis-ini, wordt geweigerd
  (kies dan een nieuwe `naam`).

### 2b. `longrun.py` — één lange run op de GPU

```bash
python3 cel/pc/longrun.py prod1 --ini notes/membranen/teamA_membranes.ini \
        --set L=256 steps=20000000 snap_every=20000 chem=1 events=1 --achtergrond
python3 cel/pc/longrun.py prod1 --achtergrond         # hervatten (na crash, reboot of --stop)
python3 cel/pc/longrun.py prod1 --steps 40000000 --achtergrond   # langer laten lopen
python3 cel/pc/longrun.py prod1 --stop                # netjes stoppen (checkpoint)
python3 cel/pc/longrun.py prod1 --analyseer-nu        # nu analyse + beelden i.p.v. over X uur
```

(Zet `NAAM` vóór `--set`, want `--set` neemt alle volgende `k=v`-woorden.)

- **Engine**: `--engine auto` (standaard) kiest `engine_gpu/oercel_gpu` als die bestaat, `nvidia-smi`
  werkt, de GPU-zelftest van setup niet faalde voor precies deze build én een proefrun van 20 stappen
  lukt (uitslag per build onthouden in `pc/_build/gpu_smoke.json`); anders `engine/oercel` op de CPU,
  met de reden in beeld (threads: GPU 2, CPU min(32, CPU's − 2)). `--engine gpu` met een GPU-engine
  die niet draait wordt geweigerd, met de reden.
  De keuze ligt vast voor de hele run (checkpoints van verschillende engines hoeven niet uitwisselbaar
  te zijn); wisselen kan alleen bewust met `--engine cpu --forceer-engine`.
- **Chunks en herstarts**: de engine draait in chunks van `--chunk-min` minuten (engine-optie
  `walltime`) en gaat steeds verder met `restart=runs/NAAM/ckpt.bin`. Gaat de engine dood (crash,
  `kill -9`), dan herstart de supervisor hem na 10, 20, 40, … s. Laadt een checkpoint niet, dan
  probeert hij de vorige bewaarde kopie (`ckpt_<stap>.bin`) — alleen als de engine meldt dat het
  checkpoint niet te lezen is, niet bij bijvoorbeeld "no CUDA device". Na 6 mislukkingen zonder
  voortgang stopt hij met status `fout` (er wordt dan niets gewist; `status.py --hervat` probeert het
  later opnieuw). Valt de GPU weg (bijv. na een Windows-driverupdate), dan staat in het log wat te doen;
  desnoods verder op de CPU met `--engine cpu --forceer-engine` (de CPU-engine leest de checkpoints van
  de GPU-engine). Wordt de supervisor zelf gedood, dan
  krijgt de engine SIGTERM en schrijft hij een checkpoint; een losgeraakte engine wordt bij de
  volgende start eerst netjes gestopt. Hetzelfde commando opnieuw = verder waar het was.
- **Elke `--analyse-uur` uur** (standaard 2; 0 = alleen aan het eind), in een aparte thread terwijl de
  engine doorloopt: `tools/analyze.py` (met `--analyse-jobs`, standaard 8 processen), dan beelden in
  `beelden/NAAM/`: `micro_<stap>.png` (hele schaal), `goodsell_<stap>_spoor<id>.png` (meest
  interessante cel: delend/dochter > met katalysatoren > generatie > levensduur), en
  `timelapse_<stap>.png` zodra er een deling is (alleen opnieuw als de delingen veranderen). Per
  soort blijven de nieuwste `--images-keep` (4) bewaard. Beelden worden eerst als `*.tmp.png` gemaakt
  en pas als ze af zijn hernoemd, dus een `kill` tijdens het tekenen laat geen halve PNG achter.
- **Schijf begrensd** (na elke analyse): de nieuwste `--keep-recent` (200) geanalyseerde snapshots
  blijven; oudere worden uitgedund met een stap die met de leeftijd verdubbelt (1 op 2, 4, 8, …,
  max 1 op `--max-stride` = 64). Altijd bewaard: snapshot 0, alles wat nog niet geanalyseerd is of
  nieuwer is dan het laatste checkpoint, en `--div-window` (10) snapshots vóór en na elke gedetecteerde
  deling (die stappen worden onthouden, ook als een latere analyse ze anders ziet). Komen de
  snapshots toch boven `--max-snap-gb` (100 GB), dan wordt de maximale stap verdubbeld. Analyse-cache
  van verwijderde snapshots gaat mee weg. Checkpoints: de nieuwste `--keep-ckpt` (3) kopieën plus de
  laatste kopie vóór elke deling (om daar later vanaf te kunnen vertakken).
- **WSL2 en de Windows-schijf**: de Linux-bestanden staan in een virtuele schijf (`ext4.vhdx`) die meegroeit
  op de Windows-schijf, normaal C:. `df` in WSL toont de virtuele schijf (tot 1 TB), niet wat er op C: vrij
  is. De scripts kijken daarom in WSL naar beide en nemen de kleinste; `status.py` toont "Windows C: vrij".
  Verwijderde snapshots maken ruimte vrij ín de virtuele schijf, maar die krimpt niet vanzelf: zet in
  PowerShell eenmalig `wsl --manage <distro> --set-sparse true` om ruimte aan Windows terug te geven.
- **Schijf vol?** Zakt de vrije ruimte onder `--min-vrij-gb` (10 GB), dan stopt de engine netjes
  (checkpoint) en wacht de supervisor (status "GEPAUZEERD"). Hij analyseert en dunt dan meteen uit
  (dat maakt vaak al genoeg ruimte vrij); is er weer 1,5× zoveel vrij, dan gaat de run vanzelf verder.
  Komen de snapshots boven `--max-snap-gb`, dan wordt er ook meteen (niet pas na `--analyse-uur`)
  geanalyseerd en uitgedund.
- **Uitvoer** in `runs/NAAM/`: de normale engine-bestanden, `STATUS.md` (kort, Nederlands: stappen,
  snelheid, tijd tot klaar, herstarts, schijf, cellen, delingen, checklist, laatste beelden — elke
  minuut bijgewerkt), `pc_longrun.json` (toestand), `pc_history.csv` (cijfers per analyse),
  `pc_supervisor.log`, `pc_engine.out` (stderr van de engine), `pc_tools.log` (analyse/beelden).
- **Varianten**: `--van-ckpt runs/X/ckpt.bin` begint een nieuwe run vanaf het checkpoint van een
  eerdere soep-run (toegestaan volgens SPEC §4; met `--set restart_reseed=1 seed=…` vertakt hij); het
  checkpoint wordt eerst gekopieerd naar `runs/NAAM/pc_van_ckpt.bin`, zodat het vertakpunt vastligt
  ook als run X doorloopt;
  `--adopteer` neemt een bestaande run-map (gemaakt met de engine direct) onder supervisie.

### 2c. Na een herstart van Windows / WSL

Processen in WSL overleven een herstart niet. Daarna (in Claude Code):

```bash
python3 cel/pc/status.py            # toont ONDERBROKEN runs met hun hervat-commando
python3 cel/pc/status.py --hervat   # start ze allemaal weer op de achtergrond
```

Tips om onderbrekingen te voorkomen: laat het terminalvenster met `claude remote-control` open
(sluiten kan WSL stoppen), zet Windows-slaapstand op "nooit" bij netstroom, en geef WSL genoeg
geheugen in `%UserProfile%\.wslconfig` (`[wsl2]` / `memory=96GB`) — standaard krijgt WSL de helft.

## 3. Wat is getest, en wat niet

Getest op de ontwikkelmachine (4 kernen, geen GPU, Ubuntu 24.04, géén WSL), met de CPU-engine,
1–2 threads en kleine dozen. De tests staan in `tests/` en zijn opnieuw te draaien, alles in één keer
met `bash cel/pc/tests/alle_tests.sh` (~30 min; op de pc ook met de echte GPU-engine:
`ENGINE_EMU=engine_gpu/oercel_gpu bash cel/pc/tests/alle_tests.sh`). Resultaten in `cel/pc/_test/`.

| test | wat het bewijst |
|---|---|
| `tests/test_longrun_kill.sh` | `kill -9` van de engine midden in een chunk, `kill -9` van de supervisor (engine stopt zelf met checkpoint), `kill -9` van beide tegelijk; daarna is alles (stats.csv, events.csv, checkpoint, alle 61 snapshots) bit-voor-bit gelijk aan een ononderbroken run |
| `tests/test_thinning.sh` | op een kopie van een echte run met een deling (`runs/memA_F0`): uitdunnen 51 → 20 snapshots, venster rond de deling blijft, nieuwe analyse vindt de deling nog steeds, micro-, Goodsell- en time-lapsebeeld gemaakt, tweede aanroep verandert niets |
| `tests/test_longrun_extra.sh` | automatische GPU-keuze (met nep-`nvidia-smi` en een nep-GPU-engine), `--stop`, kapot checkpoint → terugval op oudere kopie → toch bit-gelijk, onbekende parameter geweigerd, `--van-ckpt` |
| `tests/test_sweep_kill.sh` | 8 jobs, `kill -9` van een engine en van de sweep-supervisor, hervatten; twee jobs bit-gelijk aan ononderbroken runs; SAMENVATTING.md/.csv |
| `tests/test_longrun_kill.sh` met `ENGINE=engine_gpu/oercel_emu` | dezelfde `kill -9`-test met de CPU-emulatie-build van de GPU-engine (zelfde bron als `oercel_gpu`): ook daarmee bit-gelijk |
| `tests/test_disk_guard.sh` | schijf (gesimuleerd) bijna vol → engine pauzeert met checkpoint, gaat vanzelf verder als er ruimte is, resultaat bit-gelijk |
| `tests/test_reboot.sh` | lange run + sweep tegelijk "stroomstoring" (`kill -9` van alles), één `status.py --hervat` brengt beide terug tot het eind |
| `tests/test_gpu_fallback.sh` | GPU-engine die niet draait → CPU; `--engine gpu` dan geweigerd; zelftest gefaald → CPU; GPU die midden in een run wegvalt → géén checkpoint als kapot gemarkeerd, na terugkeer verder vanaf het nieuwste checkpoint, bit-gelijk |
| `tests/test_stop_hervat.sh` | SIGTERM van buiten (afsluiten) → `--hervat` start opnieuw; bewuste `--stop` → `--hervat` laat het staan (run én sweep); `--steps` op een draaiende run → `NIET TOEGEPAST`; bestandssysteem zonder `flock` (gesimuleerd) → vergrendeling via `/tmp`; sweep met volle schijf → jobs pauzeren met checkpoint, geen crash geteld, daarna bit-gelijk klaar |
| `tests/test_kill_stress.sh` | `kill -9` van engine / supervisor / beide **tijdens het schrijven van een checkpoint** (gericht), tijdens een snapshot, en willekeurig; `kill -9` van de supervisor tijdens `analyze.py`/`render.py` en het uitdunnen; sweep-supervisor willekeurig gedood → alles bit-gelijk, geldige JSON, geen halve bestanden of beelden |
| `setup_wsl.sh --test-functies` | versiekeuze van de toolkit (ook Ubuntu 20.04 → max. 12.x, terugvalvolgorde), parsen van `nvidia-smi`, WSL1/WSL2-herkenning |
| `setup_wsl.sh --droog` als root op een kopie van de repo van een andere gebruiker | de mappen die setup maakt (`runs/`, `runs/_setup`, `pc/_build`) zijn van de eigenaar; proefrun lukt (zo draait `wsl -u root`) |
| `setup_wsl.sh --droog` in een kopie van de repo | met nep-WSL2-kernel en nep-`nvidia-smi`: alle stappen, bouwen (ook `engine_gpu/oercel_gpu` met nvcc 12.0 + g++-12), validate.sh (29 PASS), proefrun; CUDA-testprogramma compileert voor sm_75 |

**Niet getest** (kon hier niet: geen WSL2, geen GPU, NVIDIA-downloadserver geblokkeerd):

- de echte CUDA-installatie in WSL2 (keyring-download, `apt-get install cuda-toolkit-X-Y`, de
  apt-pin tegen een echte NVIDIA-repository — de pin zelf is wel met `apt-cache policy` gecontroleerd
  tegen Ubuntu's driverpakketten);
- `cuda_check` en `engine_gpu` op een echte GPU, en `longrun.py` met de echte `oercel_gpu`
  (getest met een nep-GPU-engine die de CPU-engine is) — ook of het checkpoint-formaat van de
  GPU-engine door `pclib.ckpt_step` herkend wordt (zo niet: valt terug op log/stats, getest);
- `sudo` met wachtwoord-prompt, `.bashrc`-aanpassing bij een venv, de apt-vergrendeling, het afmaken
  van een onderbroken `dpkg`/CUDA-installatie en de terugval naar een lagere toolkit of naar
  `cuda-nvcc`+`cuda-cudart-dev` (geen root en geen NVIDIA-repository hier; `wsl -u root` is alleen
  nagebootst als root op een repo van een andere gebruiker);
- de schijfbewaking via `/mnt/c` (vrije ruimte op de Windows-schijf) en `--set-sparse`: geen WSL hier
  (alleen met een gesimuleerde waarde);
- de repo onder `/mnt/c`: alleen de waarschuwingen zijn getest; of `flock` daar werkt is onbekend (zo
  niet, dan vergrendelen de scripts via `/tmp`, getest met een gesimuleerde fout);
- prestaties en de standaardinstellingen op 64 kernen (jobs × threads) — dat moet op de pc zelf
  blijken; pas zo nodig `--jobs/--threads` aan.
