# M0 – Feasibility-spike: RESULTAT ✅ LYKKEDES

Dato: 2026-11-18. Testet i bilen på en rute på Sjælland/Lolland.

## Konklusion

**Apple Maps planlægger EV-ladestop for en maskeret VW ID.3 i Danmark.** Hele
den centrale usikkerhed, som ingen forudgående research kunne afgøre, er nu
bekræftet positivt i praksis.

## Beviser

Skærmbillede: Maps-navigation med ladestop ved **Clever (2 ladere)** på Falster,
ankomst **24 %**, 116 km til næste stop. Altså ægte EV-routing med ladeplan.

In-app-log fra build 17 (hardkodet SoC 60 %):

```
[app] Siri auth -> authorized
[app] donated INListCarsIntent
[ext] handler(for: INListCarsIntent)
[ext] INListCarsIntent -> 1 car (make=Porsche model=Taycan)
[ext] handler(for: INGetCarPowerLevelStatusIntent)
[ext] INGetCarPowerLevelStatus[handle] -> SoC 60%, charging false   (gentaget)
[ext] startSendingUpdates (Maps subscribed)
[ext] INGetCarPowerLevelStatus[update] -> SoC 60%, charging false
```

## Hvad det afgør (jf. M-1 §7–§9)

1. **Whitelist/tricket virker.** Maps kalder vores Intents-extension og bruger svaret.
2. **EV-routing er aktiv i Danmark.**
3. **Vores ID.3-formula-dictionaries accepteres.** Maps beregnede ladestop +
   ankomst-SoC: 60 %→24 % over 116 km ≈ 21 kWh/100 km. Realistisk for tallene i
   `id3.json`. (Åbent: om Maps bruger *vores* tal eller Apples Taycan-model — men
   resultatet er brugbart.)
4. **Maps abonnerer på live-opdateringer** via `startSendingUpdates` under
   navigation → M2's push-på-ændring-lag er relevant.

## Afgørende tekniske læresætninger (for reproduktion)

- **Bundle-ID:** app `com.porsche.one`, ext `com.porsche.one.extension`, eksakt.
- **Maskering:** `INCar.make/model = Porsche/Taycan` (ikke VW/ID.3).
- **model_id:** Porsches (12582912 forbrug / 12582916 ladning).
- **SiriKit på wildcard:** kan slås til via Admin-ASC-nøgle (`POST /v1/bundleIdCapabilities`).
  App Groups kan IKKE (409); keychain-deling bruges i stedet.
- **XcodeGen-fælde:** `info:`/`entitlements:` med kun `path:` OVERSKRIVER håndskrevne
  filer med tomme. Brug `INFOPLIST_FILE` + `CODE_SIGN_ENTITLEMENTS` og exclude dem
  fra sources. Uden dette mangler extensionen hele `NSExtension`-blokken.
- **iOS 26 install:** app-ikon + `LSRequiresIPhoneOS` kræves (ellers "Prøv igen
  senere"); Udviklertilstand skal slås til for Ad Hoc-apps.

## Næste: M1 — rigtige data

Erstat hardkodet 60 % med live SoC fra Smartcar via Workeren. Extensionen læser
`/status` fra Workeren i stedet for `VehicleState.hardcodedM0()`.
