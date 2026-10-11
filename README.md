# Oersoep

Een kleine kunstmatige-levensimulatie in één HTML-bestand, geïnspireerd door
een post van Fraser Price: willekeurige neurale netwerken in deeltjes, in een
"thermodynamische" cellulaire automaat, waar na een tijdje meercellige
structuren uit ontstaan door natuurlijke selectie.

Open `index.html` in een browser. Geen installatie, geen build.

## Hoe het werkt

- **Veld (de CA)**: een 96×96 raster met voedsel/energie. Energie stroomt binnen
  bij een paar langzaam drijvende bronnen, diffundeert en wordt gegeten. Een
  tweede veld is een signaalstof die cellen kunnen uitzenden en ruiken.
- **Cellen**: elk deeltje heeft een eigen neuraal netwerk (14 → 10 → 9, tanh)
  als genoom, plus 3 "kleurgenen" die alleen gebruikt worden voor
  verwantschap en weergave.
  - Zintuigen: voedsel en gradiënt, signaal en gradiënt, eigen energie, aantal
    buren, aantal bindingen, gemiddelde verwantschap van buren, 2 geheugenwaarden,
    een interne klok.
  - Acties: bewegen (x/y), binden, delen in tweeën, signaal uitzenden, energie
    delen via bindingen, aanvallen, 2 geheugenwaarden.
- **Thermodynamica**: leven, bewegen, bindingen en aanvallen kosten energie die
  als warmte verdwijnt. Het systeem wordt alleen in leven gehouden door de
  instroom. Bij de dood gaan restenergie en lichaam terug naar het veld.
- **Erfelijkheid**: bij deling krijgt het kind het netwerk van de ouder met
  kleine mutaties. Als de ouder op dat moment wil binden, blijft het kind
  vastzitten: klonale meercelligheid.
- **Selectiedruk richting samenwerking**: aanvallers stelen energie, en de kracht
  van een aanval hangt af van het aantal bindingen van aanvaller en prooi.
  Gebonden cellen hebben ook iets lagere basiskosten (gedeelde membraan).
- Als de populatie bijna uitsterft, ontstaan er spontaan nieuwe willekeurige
  cellen (abiogenese).

Klik in het beeld voor een voedselpuls. Wissel de kleuring om afstammingslijnen,
losse organismen of energieniveaus te zien.
