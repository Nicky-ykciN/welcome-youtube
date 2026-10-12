# Literatuur: hoe protocellen vanzelf groeien en delen

Voor de levensteams (stap 2 van de ladder). Opgesteld uit zoekresultaten (titels, samenvattingen,
fragmenten) en algemene kennis: **de volledige teksten zijn niet nagelezen** — arXiv en de
meeste uitgevers zijn vanuit de cloudomgeving geblokkeerd. Behandel alles hieronder als
hypothesen om te testen, niet als feiten over onze wereld.

Alles moet binnen SPEC §0 blijven: alleen wetten (krachten, lokale reacties) en een omgeving die
elk deeltje gelijk behandelt. Geen regel die weet wat een cel is.

## Wat we al weten uit onze eigen runs (team A, `membranen/teamA_TUNING.md`)
- Cellen ontstaan als **voedseldruppels** (N mengt slecht met water) die door lipiden worden
  ingepakt. Het lumen is dus bijna puur N.
- Met de voorbeeldchemie (p_syn_a 0.02) zetten de enzymen het lumen in ~1500 stappen om in
  lipide en zakt de cel in tot een vetklomp. Bij 1/100 van die snelheid lopen lumens nog steeds
  leeg, omdat N maar ~0.06 N/τ per cel door de wand terugkomt.
- Aanrakende membranen wisselen lipiden uit.
- Gevolg: **synthese moet in balans zijn met de N-instroom**. Een kleine onbalans is juist
  nuttig (zie route 2); een grote vernietigt de cel.

## Route 1 — Een nieuwe wand binnenin (Ono & Ikegami)
2D-roostermodel van abstracte chemie: katalysatoren maken membraandeeltjes; membranen ontstaan
vanzelf, houden zichzelf in stand en cellen delen. Volgens de figuren in het vervolgartikel groeit
een cel, en **als hij te groot wordt vormt zich binnenin een nieuw membraan dat hem in
dochtercellen splitst**. Cellen die te weinig membraan maken verliezen hun katalysatoren door
gaten in de wand (= dood).
- Bij ons gebeurt lipidesynthese ook ín het lumen, bij de enzymen. Als nieuwe lipiden zich
  binnenin tot een eigen dubbellaag organiseren in plaats van allemaal in de bestaande wand op
  te gaan, kan zo'n tussenwand vanzelf ontstaan.
- Knoppen: p_syn t.o.v. hoe snel nieuwe lipiden de wand bereiken (diffusie in het lumen,
  a_H_N, a_T_N), lumengrootte (voeding), aantal enzymen per cel.
- Bronnen: Ono & Ikegami, "Model of self-replicating cell capable of self-maintenance"
  (ECAL 1999, arXiv adap-org/9905002); "Selection of Catalysts through Cellular Reproduction"
  (Artificial Life VIII, 2002, arXiv nlin/0209037).

## Route 2 — Oppervlak groeit sneller dan inhoud (Zhu & Szostak; Markvoort)
Vetzuurblaasjes die gevoed worden terwijl de inhoud traag meegroeit, veranderen van bollen in
lange draden (tijdelijke mismatch tussen oppervlak- en volumegroei). **Zacht roeren** knipt die
draden in dochterblaasjes, en de inhoud blijft behouden. Meerdere cycli zijn gelukt.
- In onze druppelcellen zit die mismatch er al in: synthese verbruikt N (minder inhoud) en
  maakt lipiden (meer wand). Dan hoeft de N-instroom maar net achter te blijven bij het verbruik
  om de cel langwerpig te maken in plaats van hem te laten instorten.
- Gelijkmatig zacht roeren (stir_A, Kolmogorov-kracht op álle deeltjes) is toegestaan
  omgevingsfysica en is precies wat in het lab werkt.
- Knoppen: p_syn, a_T_N (doorlaatbaarheid), feed/feed_cap, stir_A.
- Bronnen: Zhu & Szostak, "Coupled growth and division of model protocell membranes", JACS 131
  (2009) 5705; Markvoort et al., "Self-reproduction of fatty acid vesicles: a combined
  experimental and simulation study", Biophys. J. 99 (2010) 1520.

## Route 3 — Ongelijke binnen- en buitenlaag (Markvoort 2010)
Deling wordt aangestuurd door een onbalans tussen de twee lagen van de membraan: nieuw materiaal
komt eerst in één laag terecht. Snellere of tragere uitwisseling tussen de lagen (flip-flop)
verandert de uitkomst.
- Bij ons komen nieuwe lipiden van binnenuit, dus de binnenlaag krijgt een overschot. Dat geeft
  kromming, instulping en mogelijk afsnoering naar binnen. De flip-flop-snelheid hangt af van
  staartlengte en kopgrootte (lip_nT, lipidevorm).

## Route 4 — Osmotische competitie = selectie (Chen, Roberts & Szostak 2004)
Blaasjes met veel ingesloten, niet-doorlaatbaar materiaal (RNA, suiker) staan onder druk en
**trekken membraan weg bij lege buurblaasjes**: ongeveer 25% van het membraan ging over. Wie
meer "inhoud" maakt, groeit ten koste van de rest. Dat is darwinistische competitie op
celniveau, zonder dat iemand die regel heeft ingebouwd.
- Onze enzymen kunnen niet door de wand en aanrakende membranen wisselen lipiden uit, dus de
  ingrediënten zijn er. Meet of cellen met meer enzymen lipiden winnen van buren.
- Bron: Chen, Roberts & Szostak, "The emergence of competition between model protocells",
  Science 305 (2004) 1474.

## Route 5 — Patroonvorming binnenin (Macía & Solé)
Een reactie-diffusiesysteem in de cel (activator/remmer) kan symmetrie breken en lokaal meer
membraan laten maken, wat tot deling leidt. Dit vraagt extra chemische soorten (lokale wetten,
toegestaan), maar is complexer. Bewaren voor later.
- Bronnen: Macía & Solé, "Protocell self-reproduction in a spatially extended metabolism-vesicle
  system" (arXiv q-bio/0511041); "Synthetic Turing protocells: vesicle self-reproduction through
  symmetry-breaking instabilities" (arXiv q-bio/0607035).

## Verwante simulaties in dezelfde methode (DPD)
- Fellermann & Solé, "Minimal model of self-replicating nanocells: a physically embodied
  information-free scenario", Phil. Trans. R. Soc. B 362 (2007), arXiv q-bio/0607027: in DPD
  delen aggregaten die door hun eigen metabolisme groeien, zonder informatiemoleculen.
- Fellermann, Rasmussen, Ziock & Solé, "Life cycle of a minimal protocell — a dissipative
  particle dynamics study", Artificial Life 13 (2007) 319, arXiv nlin/0612024: volledige
  levenscyclus met container, metabolisme en genetica (3D).
- Cabaret, "Emergence of autopoietic vesicles able to grow, repair and reproduce in a minimalist
  particle system" (arXiv 2311.10761, 2023/2024): 2D-deeltjessimulatie waarin zichzelf
  onderhoudende blaasjes ontstaan uit willekeurig verspreide componenten, groeien, zich
  herstellen en voortplanten, waarbij de inhoud wordt doorgegeven. Dit ligt het dichtst bij ons
  doel. **Op de pc (daar is arXiv bereikbaar) als eerste volledig lezen.**

## Tijdschalen
Delingscycli in zulke simulaties duren lang. Reken op 10^5–10^6 stappen per cyclus voordat je
concludeert dat iets niet werkt, en gebruik meerdere zaden (seeds).
