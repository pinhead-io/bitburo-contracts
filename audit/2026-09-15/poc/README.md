# Proof-of-concepts bij de audit van 15 september 2026

Deze map is het archief zoals de audit hem opleverde. De bestanden hier draaien **niet** mee met
`forge test`: ze staan buiten het testpad en een deel gebruikt de importpaden van een los
scratch-project (`repo/...`).

## Overgenomen in de suite

| PoC | Waar nu | Wat ermee gebeurd is |
|---|---|---|
| `AuditMath.t.sol` | `test/AuditMath.t.sol` | Ongewijzigd overgenomen bij de verharding. |
| `CrePoC.t.sol` | `test/CrePoC.t.sol` | Vier tests op het `onReport`-oppervlak ongewijzigd. PoC-1 (slot-starvation) omgeschreven: de stof-params zijn sinds de verharding niet meer te registreren, dus de test asserteert nu de weigering en de fee die de goedkoopst toegestane run wél kost. |
| `PocFork.t.sol` | `test/PocFork.t.sol` | Feed bijgewerkt naar `0x9867…01e0` (audit M-2). De twee stof-tests zijn samengevoegd tot één test die asserteert dat de opzet wordt geweigerd. De sandwich-test asserteert nu dat `execute` revert met `SpotDeviatesFromOracle`. |
| `OracleSandwich.t.sol` | `test/OracleSandwich.t.sol` | Feed bijgewerkt. De 30-bps-variant is 60 bps geworden, de krapst toegestane stand sinds audit L-2. De assertie van de 10k-variant is omgekeerd: de aanval hoort níet meer te lonen. |
| `PocStarvation.t.sol` | vervallen | Dezelfde aanval als PoC-1 van `CrePoC`, met dezelfde mocks. De herschreven test daar dekt het; een tweede kopie voegde niets toe. |

## Niet overgenomen

`GasProbe.t.sol` en `CreForkGas.t.sol` zijn eenmalige metingen zonder asserties. Ze dienden om
`EXECUTE_GAS` te ijken, wat tot de verhoging van 700.000 naar 1.000.000 leidde. `CreForkGas.t.sol`
heeft bovendien het inmiddels vervangen contractadres `0xED47…e6e5` hard gecodeerd. Wie opnieuw wil
meten, kopieert ze naar `test/` en past het adres aan.

## Wat de omgeschreven tests aantonen

De PoC's reproduceerden niet meer op het verharde contract. Dat is het resultaat, niet een probleem:

- Stof-owners zijn niet meer te registreren. `MIN_TRADE_FLOOR` (20 EURC), `MIN_CORRECTION_BPS` (10) en
  `MIN_SLIPPAGE_BPS` (60) weigeren elke dimensie van de oorspronkelijke opzet.
- De zelf-sandwich uit M-1 levert niets meer op. Bij zowel 60 als 100 bps slippage kapt de router de
  aanval af met "Too little received", verdient de aanvaller niets boven de gewone beloning van
  0,05 EURC, en verliest het slachtoffer niets. `_requireSpotNear` draait sinds de verharding ook ná
  de swap, dus voorschuiving en eigen prijsimpact moeten samen binnen de tolerantie blijven.

De omgeschreven tests leggen dat vast: gaat een van die eigenschappen ooit verloren, dan falen ze.
