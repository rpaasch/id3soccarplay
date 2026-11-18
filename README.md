# ID.3 Apple Maps EV routing (privat)

En iOS-app med Intents-extension, der skal give Apple Maps (iPhone + CarPlay)
kendskab til en VW ID.3's batteriniveau, så Maps selv kan planlægge ladestop.
Kun til privat brug, installeres Ad Hoc. Ikke App Store, ikke TestFlight.

Se `docs/M-1-afklaring.md` for research, usikkerheder og den fulde
engangstjekliste. **Læs især §7–§8: det er stærkt usikkert, om tricket virker,
og hele projektet står og falder med M0-testen i bilen.**

## Status

- **M-1 Afklaring** ✅ — se `docs/M-1-afklaring.md`.
- **M0 Feasibility-spike** 🔨 — projektet her. Hardkodet SoC 60 %, ID.3-profil,
  Porsche/Taycan-maskering. Bygger i GitHub Actions (compile-check kører nu;
  signeret Ad Hoc-IPA aktiveres, når ASC-nøgle + Cloudflare er på plads).
- M1+ — ikke startet.

## Arkitektur (M0)

```
Sources/
  App/         SwiftUI-værtsapp: status, Siri-tilladelse, log-eksport
  Extension/   Intents-extension: INListCarsIntent + INGetCarPowerLevelStatusIntent
  Shared/      Delt kode (profil, log via keychain-gruppe, Maps-svar)
Resources/
  id3.json     Bilprofil: kapacitet, connectors, forbrugs-/ladedictionaries (ESTIMATER)
.github/workflows/ios.yml   XcodeGen → build
```

- **Bundle-ID:** app `com.porsche.one`, extension `com.porsche.one.extension`
  (eksakt, pga. VirtualGarage Siri-allowlist — se M-1 §8).
- **Ingen App Groups** (wildcard-profil tillader det ikke). Data deles via
  shared keychain-gruppe `com.porsche.one.shared`.
- **make/model = Porsche/Taycan** i Maps; ID.3-tal ligger i formula-dictionaries.

## Byg lokalt (kræver Mac, som vi ikke har)

```bash
brew install xcodegen
xcodegen generate
open ID3Maps.xcodeproj
```

Alt bygges ellers i skyen via GitHub Actions. Se workflow-filen.

## Testprocedure i bilen (M0-succeskriterium)

1. Installér IPA'en via install-linket (kommer, når signering er på plads).
2. Åbn appen én gang, tryk "Anmod om Siri-tilladelse" og "Send testinteraktion".
3. iPhone → Apple Maps → profil → **Køretøjer**: dukker "VW ID.3" op?
4. Planlæg en lang rute (fx København–Aarhus). Foreslår Maps ladestop?
5. Eksportér loggen fra appen og del den, så vi kan se, hvilke intents Maps kaldte.

Virker det ikke, stopper vi her og falder tilbage på ABRP i CarPlay (M1 genbruges).
