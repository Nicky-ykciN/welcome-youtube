# Oercel starten op je werkplek

Nodig: Windows 11 met **Ubuntu (WSL2)**, de gewone **NVIDIA-driver voor Windows**, een
**Claude-abonnement** (Pro, Max, Team of Enterprise) en ongeveer **100 GB vrij op schijf C:**
(daar staat de Linux-schijf van Ubuntu). Verder hoef je niets te installeren.

## Stap voor stap

1. Open **Ubuntu** (Start-menu → "Ubuntu": een zwart venster). De allereerste keer vraagt Ubuntu
   een gebruikersnaam en een wachtwoord: kies ze en onthoud het wachtwoord.
2. Typ dit (of plak het met de rechtermuisknop) en druk op Enter:

   ```
   git clone https://github.com/Nicky-ykciN/welcome-youtube ~/welcome-youtube
   ```

   Zo komt alles in je Linux-thuismap. **Niet** onder `/mnt/c`: daar is alles tien keer trager.
3. `cd ~/welcome-youtube`
4. `bash cel/pc/start.sh`
5. Meteen daarna vraagt hij om je **wachtwoord**: typ je Linux-wachtwoord (je ziet niets terwijl je
   typt) en Enter. Dat is één keer. (Niet te lang wachten: na een paar minuten geeft sudo het op.)
6. Wacht. De eerste keer duurt de installatie **20 tot 50 minuten** (CUDA downloaden, alles bouwen
   en testen). Je mag weglopen.
7. Daarna vraagt hij je **in te loggen bij Claude**. Er opent een browser, of je krijgt een link
   (Ctrl+klik). Log in. Toont de browser een code: kopieer die, plak hem in het Ubuntu-venster
   (rechtermuisknop) en druk op Enter.
8. Druk op Enter om naar het Claude-venster te gaan, en beantwoord de vragen:
   - `Enable Remote Control? (y/n)` → **y** en Enter
   - `Trust ...?` (vertrouw je deze map?) → **y** en Enter
   - een andere vraag (bijvoorbeeld een kleurenschema kiezen, of "Press Enter") → **Enter**
9. Zie je een link naar claude.ai/code, dan is het klaar. Druk **Ctrl+b**, laat los, druk **d**:
   je bent terug in Ubuntu en Claude blijft draaien.
   Te vroeg teruggegaan, voordat je de vragen had beantwoord? Typ dan nog eens `bash cel/pc/start.sh`:
   hij brengt je terug naar de vraag.
10. Open de **Claude-app** (telefoon, of claude.ai/code) → **Code** → **Oercel werkstation**.
    Vanaf nu praat je daar met Claude. Vraagt Claude daar toestemming om iets uit te voeren, geef die
    dan; meestal kun je ook kiezen dat hij het voor die opdracht niet opnieuw vraagt.
11. Laat het Ubuntu-venster open (minimaliseren mag) en zet de slaapstand van Windows op **Nooit**
    (Instellingen → Systeem → Energie), anders pauzeert alles als de pc gaat slapen.

## Wat gebeurt er daarna?

Meteen na de installatie starten de experimenten uit `cel/pc/plan.txt` vanzelf, op de achtergrond:

- **oersoep_groot** — de grote proef op de GPU: een soep van 512 × 512 met chemie aan. Duurt naar
  schatting een halve dag tot 3 dagen (hoe snel de GPU is, is nog nooit gemeten). Elke 2 uur nieuwe
  beelden in `cel/beelden/oersoep_groot/`.
- **leven_scan** — 108 kleine proeven op de 64 kernen, 54 tegelijk (geschat 3 tot 5 uur), om te zien
  welke instellingen cellen laten eten, groeien en delen.

Claude kijkt mee, laat je beelden zien en zegt eerlijk wat wel en niet werkt. Hij past het plan aan
en start nieuwe proeven als dat nodig is. Zolang de afgestemde chemie (`engine/params/production.ini`)
er nog niet is, gebruikt oersoep_groot een voorzichtige gok; dat staat in `plan.txt`.

**De beelden zelf bekijken in Windows:** typ in Ubuntu
`cd ~/welcome-youtube/cel/beelden && explorer.exe .` — dan opent de map in de Windows-Verkenner.

## Hoe gaat het?

Vraag het Claude in de app, of typ in Ubuntu (in `~/welcome-youtube`): `python3 cel/pc/status.py`

## Stoppen

- `bash cel/pc/stop.sh` — stopt alle proeven netjes (er gaat niets verloren). Claude blijft draaien.
- `bash cel/pc/stop.sh --alles` — stopt ook Claude.
- Weer verder: `bash cel/pc/start.sh`

## Na een herstart van de pc

Open Ubuntu en typ: `cd ~/welcome-youtube && bash cel/pc/start.sh`

Meer niet: de installatie wordt overgeslagen, elke proef gaat verder waar hij was, en Claude start
weer. Je mag `start.sh` altijd opnieuw draaien; het doet nooit iets dubbel. (Ook Windows Update
kan de pc 's nachts herstarten; doe dan hetzelfde.)

## Als iets niet werkt

- **`nvidia-smi` werkt niet / geen GPU** — werk de NVIDIA-driver in **Windows** bij
  (nvidia.com/drivers → Quadro RTX 8000), herstart de pc (of in PowerShell: `wsl --shutdown`) en
  draai `start.sh` opnieuw. Installeer géén driver in Ubuntu. De proeven op de CPU lopen intussen
  gewoon; de GPU-proef wacht tot de GPU werkt.
- **Linux-wachtwoord vergeten** — in Windows PowerShell: `wsl -u root passwd JOUWNAAM` (JOUWNAAM =
  je Ubuntu-gebruikersnaam; die staat in Ubuntu vóór de `@`). Kies een nieuw wachtwoord.
- **`git: command not found`** (stap 2) — typ `sudo apt update && sudo apt install -y git` en doe
  stap 2 opnieuw.
- **"destination path ... already exists"** (stap 2) — de repo staat er al: ga gewoon verder met stap 3.
- **`claude: command not found`** — open een nieuw Ubuntu-venster (start.sh heeft `~/.local/bin` aan
  je `PATH` in `~/.bashrc` toegevoegd), of typ `export PATH="$HOME/.local/bin:$PATH"`.
  Controleren: `claude --version`; problemen zoeken: `claude doctor`.
- **De repo staat onder `/mnt/c`** — start.sh maakt dan zelf een kopie in `~/welcome-youtube` en gaat
  daar verder. Gebruik voortaan die. Lukt het niet: doe stap 2 opnieuw.
- **Foutmelding met `$'\r'`** — de repo is met Git voor Windows gekloond. Doe stap 2 in Ubuntu.
- **Inloggen lukt niet** — typ `~/.local/bin/claude auth login` (zo werkt het ook in hetzelfde
  venster), daarna weer `bash cel/pc/start.sh`. Remote Control werkt alleen met een abonnement, niet
  met een API-sleutel.
- **Claude reageert niet in de app** — typ in Ubuntu `bash cel/pc/start.sh`: dat start Claude opnieuw
  als hij weg is, en brengt je naar het Claude-venster als hij op een antwoord wacht. Zelf meekijken:
  `tmux attach -t oercel-claude` (terug: Ctrl+b, dan d).
- Logboeken: installatie in `cel/runs/_setup/`, Claude in `cel/pc/_build/claude_rc.log`.
