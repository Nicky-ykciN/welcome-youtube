# Oercel starten op je werkplek

Nodig: Windows 11 met **Ubuntu (WSL2)**, de gewone **NVIDIA-driver voor Windows**, een
**Claude-abonnement** (Pro, Max, Team of Enterprise), je **GitHub-account** (het account dat op deze
repo mag schrijven) en ongeveer **100 GB vrij op schijf C:** (kijk in Verkenner → Deze pc). Verder hoef
je niets te installeren. Reken op ongeveer een uur; het grootste deel daarvan mag je weglopen.

**Even vooraf**

- Open deze pagina **op de pc zelf** (github.com/Nicky-ykciN/welcome-youtube → STARTEN.md). Dan kun je
  de commando's kopiëren: een grijs blok heeft rechtsboven een kopieerknopje.
- **Ubuntu-venster** = het zwarte tekstvenster van Ubuntu (een "terminal"). Een **commando** typ of plak
  je daarin en je drukt daarna op **Enter**. Plakken = **rechtermuisknop** (of Ctrl+V).
- Ubuntu is klaar voor een commando als de laatste regel eindigt op `$` (zoals `naam@pc:~$`).
- **Repo** = de projectmap van GitHub. Op je pc heet hij `~/welcome-youtube` (`~` = je Linux-thuismap).

## Stap voor stap

1. Zet eerst de **slaapstand van Windows op Nooit**: Instellingen → Systeem → Energie → Scherm en
   slaapstand → slaapstand **Nooit** (het scherm mag wel uit). Anders pauzeert alles als de pc gaat
   slapen, ook de installatie.
2. Open **Ubuntu**: Start-menu, typ `Ubuntu`, klik erop. Er opent een zwart venster. De allereerste keer
   vraagt Ubuntu een gebruikersnaam en een wachtwoord: kies ze en **onthoud het wachtwoord** (je ziet
   niets terwijl je het typt; dat is normaal).
3. Kopieer dit, plak het in het Ubuntu-venster en druk op Enter. Zo komt het project van GitHub op je
   pc (dat heet "klonen"):

   ```
   git clone https://github.com/Nicky-ykciN/welcome-youtube ~/welcome-youtube
   ```

   Klaar als er weer een regel met `$` staat.
4. Ga naar de projectmap (plakken, Enter):

   ```
   cd ~/welcome-youtube
   ```

5. Start alles (plakken, Enter):

   ```
   bash cel/pc/start.sh
   ```

6. Meteen daarna vraagt hij je **wachtwoord** (`[sudo] password for ...`): typ je Linux-wachtwoord (je
   ziet niets terwijl je typt) en Enter. Dat is één keer. Blijf erbij tot dit gedaan is: na een paar
   minuten geeft hij het op. Zie je `Sorry, try again`: typ het nog eens. Lukt het niet: druk **Ctrl+C**
   en doe stap 5 opnieuw.
7. Wacht. De eerste keer duurt de installatie **20 tot 50 minuten** (CUDA downloaden, alles bouwen en
   testen); er komt veel tekst voorbij. Je mag weglopen, maar **sluit het venster niet**. (Toch dicht?
   Open Ubuntu en doe stap 4 en 5 opnieuw: hij vraagt weer je wachtwoord, en wat al klaar was gaat snel.)
8. Klaar met installeren? Dan hoor je een piepje en zie je **Nu één keer inloggen bij Claude**. (Staat er
   ergens rood `FOUT`? Ga gewoon door; Claude zoekt het later uit.) Er opent een browser, of je krijgt
   een link: houd **Ctrl** ingedrukt en klik erop. Log in met je Claude-account. Toont de browser een
   code: kopieer die, plak hem in het Ubuntu-venster en druk op Enter. Gelukt: je ziet groen `OK`.
   Krijg je in plaats daarvan een Claude-scherm met vragen? Kleur kiezen → Enter; inlogmethode → kies
   **Claude account with subscription**; log in zoals hierboven; andere vragen → Enter. Typ daarna
   `/exit` en Enter.
9. Meteen daarna log je **één keer in bij GitHub**, zodat Claude de resultaten op GitHub kan bewaren.
   Eerst vraagt hij `Authenticate Git with your GitHub credentials? (Y/n)`: druk op **Enter** (= ja).
   Dan zie je een code van 8 tekens (zoals `ABCD-1234`); die blijft in beeld. Druk op Enter: de browser
   opent github.com/login/device (gebeurt dat niet, ga daar dan zelf heen in je browser). Log in bij
   GitHub, typ de code, klik **Continue** en daarna **Authorize**. Vraagt het Ubuntu-venster daarna nog
   iets: Enter. (Overslaan kan met Ctrl+C; alles werkt dan, alleen kan Claude niets op GitHub zetten.)
10. Druk op Enter (of wacht 30 seconden): je komt in het **Claude-venster**. Beantwoord daar de vragen:
    - `Enable Remote Control? (y/n)` → **y** en Enter
    - `Trust ...?` (vertrouw je deze map?) → **y** en Enter
    - een andere vraag (bijvoorbeeld een kleurenschema kiezen, of "Press Enter") → **Enter**

    Druk in dit venster **niet** op Ctrl+C: dan stopt Claude.
11. Zie je een link naar claude.ai/code, dan is het klaar. Ga terug: druk **Ctrl+b**, laat los, druk
    **d**. Je bent terug in Ubuntu, Claude blijft draaien, en je ziet een **Samenvatting**. Staat daar
    nergens `FOUT` of `niet ingelogd`, dan is alles gelukt (anders: zie "Als iets niet werkt").
    Te vroeg teruggegaan, voordat je de vragen had beantwoord? Typ dan nog eens `bash cel/pc/start.sh`:
    hij brengt je terug naar de vraag.
12. Open de **Claude-app** (telefoon, of claude.ai/code in de browser) → **Code** → **Oercel
    werkstation**. Vanaf nu praat je daar met Claude, gewoon in het Nederlands. Zijn vaste
    experimentcommando's doet Claude zonder te vragen; voor iets anders vraagt hij in de app om
    toestemming: lees kort wat het is en geef die.
13. Laat het Ubuntu-venster open (minimaliseren mag). Zijn alle Ubuntu-vensters dicht, dan kan Windows
    Ubuntu stilleggen en stopt alles.

## Wat gebeurt er daarna?

Meteen na de installatie starten de experimenten uit `cel/pc/plan.txt` vanzelf, op de achtergrond (ook
al terwijl je nog inlogt):

- **oersoep_groot** — de grote proef op de GPU: een soep van 512 × 512 met chemie aan. Duurt naar
  schatting een halve dag tot 3 dagen (hoe snel de GPU is, is nog nooit gemeten). Elke 2 uur nieuwe
  beelden in `cel/beelden/oersoep_groot/`. Werkt de GPU niet, dan wacht deze proef.
- **leven_scan** — 108 kleine proeven op de 64 kernen, 54 tegelijk (geschat 3 tot 5 uur), om te zien
  welke instellingen cellen laten eten, groeien en delen.

Claude kijkt mee, bekijkt de beelden, zegt eerlijk wat wel en niet werkt en bewaart notities en beelden
op GitHub. Hij past het plan aan en start nieuwe proeven als dat nodig is. Zolang de afgestemde chemie
(`engine/params/production.ini`) er nog niet is, gebruikt oersoep_groot een voorzichtige gok; dat staat
in `plan.txt`.

## De beelden zelf bekijken

- **Op de pc:** typ in Ubuntu `cd ~/welcome-youtube/cel/beelden && explorer.exe .` — de map opent in
  de Windows-Verkenner; dubbelklik een plaatje. (Of in de Verkenner links onderaan: **Linux** → Ubuntu →
  home → jouw naam → welcome-youtube → cel → beelden.)
- **Op je telefoon:** github.com/Nicky-ykciN/welcome-youtube → cel → beelden (zodra Claude ze op GitHub
  heeft gezet).
- Of vraag Claude in de app welke beelden nieuw zijn en wat erop te zien is.

## Hoe gaat het?

Vraag het Claude in de app, of typ in Ubuntu: `cd ~/welcome-youtube && python3 cel/pc/status.py`

## Stoppen

Typ in Ubuntu eerst `cd ~/welcome-youtube`, en dan:

- `bash cel/pc/stop.sh` — stopt alle proeven netjes (er gaat niets verloren). Claude blijft draaien.
- `bash cel/pc/stop.sh --alles` — stopt ook Claude.
- Weer verder: `bash cel/pc/start.sh`

## Na een herstart van de pc (of als het Ubuntu-venster toch dicht is gegaan)

Open Ubuntu en typ: `cd ~/welcome-youtube && bash cel/pc/start.sh`

Meer niet: elke proef gaat verder waar hij was, en Claude start weer (in de app weer onder Oercel
werkstation). Schakelt hij naar het Claude-venster, dan wacht Claude op een antwoord: beantwoord het
zoals in stap 10 en ga terug met Ctrl+b, d. Was de installatie de vorige keer niet helemaal gelukt, dan
probeert hij die opnieuw en vraagt hij weer je wachtwoord; anders slaat hij de installatie over. Je mag
`start.sh` altijd opnieuw draaien; het doet nooit iets dubbel.

Windows Update kan de pc 's nachts herstarten; doe dan hetzelfde. Tip: zolang de grote proef loopt,
Instellingen → Windows Update → **Updates onderbreken**. Reageert Claude in de app ineens niet meer,
kijk dan eerst of de pc herstart is.

## Als iets niet werkt

- **`nvidia-smi` werkt niet / geen GPU** (in de Samenvatting staat `FOUT` bij GPU) — werk de
  NVIDIA-driver in **Windows** bij (nvidia.com/drivers → Quadro RTX 8000) en herstart de pc (of: open
  PowerShell via het Start-menu en typ `wsl --shutdown`). Daarna Ubuntu openen en
  `cd ~/welcome-youtube && bash cel/pc/start.sh`. Installeer géén driver in Ubuntu. De proeven op de CPU
  lopen intussen gewoon; de GPU-proef wacht tot de GPU werkt.
- **Linux-wachtwoord vergeten** — in Windows PowerShell: `wsl -u root passwd JOUWNAAM` (JOUWNAAM =
  je Ubuntu-gebruikersnaam; die staat in Ubuntu vóór de `@`). Kies een nieuw wachtwoord.
- **`git: command not found`** (stap 3) — typ `sudo apt update && sudo apt install -y git` en doe
  stap 3 opnieuw.
- **"destination path ... already exists"** (stap 3) — de repo staat er al: ga gewoon verder met stap 4.
- **`claude: command not found`** — open een nieuw Ubuntu-venster (start.sh heeft `~/.local/bin` aan
  je `PATH` in `~/.bashrc` toegevoegd), of typ `export PATH="$HOME/.local/bin:$PATH"`.
  Controleren: `claude --version`; problemen zoeken: `claude doctor`.
- **De repo staat onder `/mnt/c`** — start.sh maakt dan zelf een kopie in `~/welcome-youtube` en gaat
  daar verder. Gebruik voortaan die. Lukt het niet: doe stap 3 opnieuw.
- **Foutmelding met `$'\r'`** — de repo is met Git voor Windows gekloond. Doe stap 3 in Ubuntu.
- **GitHub-inloggen overgeslagen of mislukt** — draai `bash cel/pc/start.sh` opnieuw: dan vraagt hij het
  nog eens (zie stap 9). Of zelf: `gh auth login --web` (bij elke vraag Enter), daarna `gh auth setup-git`.
- **Inloggen bij Claude lukt niet** — typ `~/.local/bin/claude auth login`, daarna weer
  `bash cel/pc/start.sh`. Remote Control werkt alleen met een abonnement, niet met een API-sleutel.
- **Claude reageert niet in de app** — typ in Ubuntu `cd ~/welcome-youtube && bash cel/pc/start.sh`: dat
  start Claude opnieuw als hij weg is, en brengt je naar het Claude-venster als hij op een antwoord wacht.
  Zelf meekijken: `tmux attach -t oercel-claude` (terug: Ctrl+b, dan d).
- **"start.sh draait al (in een ander venster)"** — er staat nog een Ubuntu-venster open waarin hij bezig
  is: kijk daar.
- Logboeken (voor Claude): installatie in `cel/runs/_setup/`, Claude in `cel/pc/_build/claude_rc.log`.
