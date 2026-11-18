# M-1 – Afklaring

Status pr. 2026-11-18. Kilder: `augard/evmaps` @ `4c07fbc` (2026-10-23), `isaacwisdom/egmp-carplay-ev-routing` @ `2f5e5c4` (2026-11-12) og officiel dokumentation fra Apple og Smartcar. Udsagn markeret **[usikkert]** er ikke verificeret.

---

## 1. Bundle-ID'er og signering i evmaps

### Sådan er det sat op

| Target | `PRODUCT_BUNDLE_IDENTIFIER` | Entitlements |
|---|---|---|
| App (KiaMaps) | `com.porsche.one` | `com.apple.developer.siri`, `keychain-access-groups = $(AppIdentifierPrefix)com.porsche.one.shared` |
| Intents-ext. | `com.porsche.one.extension` | kun `keychain-access-groups` (samme gruppe) |
| UI-ext. | `com.porsche.one.KiaExtensionUI` | kun `keychain-access-groups` |

- Signeringen er manuel med én wildcard-profil (`com.porsche.*`) til alle tre targets. Den sættes via `Config/Signing.xcconfig`, som er gitignored.
- Alle tre `.entitlements`-filer hardkoder `application-identifier = $(AppIdentifierPrefix)com.porsche.one`, også extensionernes. Det går igennem, fordi wildcard-profilen tillader `TEAMID.com.porsche.*`. Det ligner copy-paste, og jeg kopierer det ikke.
- **Der bruges ingen App Groups.** Commit `a8916d7` hedder "credential sharing *without app groups* for extensions". Data deles i stedet via shared keychain-gruppe og `UserDefaults.standard` (som reelt ikke deles mellem processer) plus en lokal `NWListener`-server på port 8765. Det er stærk indirekte evidens for, at App Groups ikke kan bruges med wildcard-profilen.
- **Første commit (2024-06)** brugte extension-ID'et `com.porsche.one.voltron-extension`, som ligner Porsches egen interne navngivning. Forfatteren har altså forsøgt at efterligne Porsches rigtige app-ID'er præcist.

### Præfiks eller præcist ID?

- `com.porsche.kiamaps` findes **kun i `CLAUDE.md`**, som er en AI-genereret vejledning, og i en logger-fallback-streng. Det bundle-ID, der faktisk bygges, er overalt `com.porsche.one`, og repoet har ingen issues eller discussions, der siger andet.
- **Konklusion:** der er ingen evidens for, at præfikset er nok. Mønstret, hvor Porsches egne ID'er efterlignes præcist, peger på eksakt match.
- Mit skøn er, at plan A (`com.porsche.<unikt>`) har cirka 15 % chance [usikkert]. Til gengæld er den billig at teste (se nedenfor).

### Holder Ad Hoc + wildcard med Siri og App Groups?

- **App Groups: nej.** Apple DTS (Quinn) skriver: *"…com.apple.security.application-groups … must be allowlisted by a non-wildcard profile"*. Portalen deaktiverer checkboxen for wildcard-ID'er.
- **SiriKit: sandsynligvis nej** [usikkert]. Der findes rapporter om fejlen *"Team Profile wildcard doesn't include the com.apple.developer.siri entitlement"*.
  - Det modsiger evmaps' README, som både slår SiriKit og App Groups til på wildcard-ID'et.
  - Det bliver afgjort, når ID'et oprettes: enten nægter API'et eller portalen, eller også står `com.apple.developer.siri` i den dekodede profil.
  - Hvis ikke, bygger vi uden Siri-entitlement. Det er ukendt, om Maps kræver det til car-intents, men brugeren kalder aldrig Siri selv.
- **Keychain access groups virker med wildcard.** Profilen tillader `TEAMID.*`.

**Konsekvenser for din arkitektur (plan B):**
- "App Group til log og cache" erstattes af en **shared keychain-gruppe** `$(AppIdentifierPrefix)com.porsche.one.shared`. Den bruges til Worker-token, cache og en ringbuffer til loggen på cirka 100 KB.
- **Remote log:** både app og extension sender også logevents til Workeren (`POST /log`). Så kan jeg selv læse intent-kaldene fra Maps med `wrangler`, uden at du skal eksportere noget. Eksport via share sheet bevares.

### Plan A og B samtidig i M0

De to apps har forskellige bundle-ID'er og kan ligge side om side på telefonen med hvert sit visningsnavn ("ID.3 (A)" og "ID.3 (B)"). Én tur i Maps → Køretøjer afgør så spørgsmålet direkte.

- **Plan A:** eksplicit `com.porsche.<unikt>`. Her virker Siri og App Groups normalt. Distribueres via TestFlight og kræver en App Store Connect-post.
- **Plan B:** wildcard `com.porsche.*` med bundle-ID `com.porsche.one`. Ad Hoc via `itms-services`.
- Antagelse: din konto kan registrere `com.porsche.*` og `com.porsche.<unikt>` [usikkert]. Bundle-ID'er er globalt unikke, og Porsche har næsten sikkert registreret `com.porsche.one` eksplicit. Wildcard-ID'et har evmaps' forfatter tilsyneladende fået lov at registrere.

---

## 2. De to formula-dictionaries

Begge sættes på `INGetCarPowerLevelStatusIntentResponse` som `[String: Any]`:

```text
consumptionFormulaArguments = {
  "model_id": Int,                                   // evmaps: 12582912 (0xC00000)
  "vehicle_parameters": {
    "vehicle_auxiliary_power_w": Double,             // 670 (Taycan), 400 (Ioniq 5)
    "vehicle_consumption_values_wh_per_m": [Double] × 10,
    "vehicle_altitude_gain_consumption_wh_per_m": Double,   // 8.346 / 6.42
    "vehicle_altitude_loss_consumption_wh_per_m": Double    // 6.973 / 4.33 (positiv værdi)
  }
}
chargingFormulaArguments = {
  "model_id": Int,                                   // evmaps: 12582916 (0xC00004)
  "vehicle_parameters": {
    "vehicle_energy_axis_wh": [Number],              // stigende, 0 … kapacitet
    "vehicle_charge_axis_w":  [Number],              // samme længde, effekt pr. punkt
    "energy_w_per_h":         [Number] × 21,         // ukendt betydning, kopieres
    "efficiency_factor":      Double                 // 0.9 / 0.95
  }
}
```

**Observationer:**

- **Enhederne er korrekte, og kommentarerne har ret.** 0,172 Wh/m er numerisk lig 0,172 kWh/km (172 Wh/km). Wh/m og kWh/km er samme størrelse, så der er ingen fejl.
- **Taycan-værdierne ser ud til at være opsnappet fra Porsches rigtige app.** Tal som `669.9999809265137` er float32→double-artefakter. Det taler for, at formatet er ægte.
- **Forbrugsvektoren er ikke monoton:** 225, 182, 193, 214, 172, 172, 183, 205, 227, 258 Wh/km. Ingen ved, hvad de 10 positioner betyder (hastighedsbins? temperatur?).
  - egmp genbruger Taycans 10 værdier uændret til Ioniq 5 og hævder alligevel 1–2 % præcision. Det tyder på, at Maps vægter vektoren svagt, eller at tallene er generiske.
  - Til ID.3 skalerer jeg vektoren efter ID.3-forbrug og bevarer formen. Det er et estimat.
- **Længden af lade-aksen er fri.** evmaps bruger 41 punkter, egmp 11. `energy_w_per_h` er 21 punkter i begge, med identiske værdier op til 77050.
- **`model_id` er ikke bil-ID'et.** Porsche-appen bruger 0xC00000 og 0xC00004. egmp bruger 0xC00009 og 0xC0000A over iAP2, og de skriver selv, at *"the Porsche app's model IDs are different"*. Jeg bruger evmaps' ID'er, fordi vi går samme vej (Intents) som Porsche-appen.
- **Bug i evmaps:** `maximumBatteryCapacity` sendes i kJ, men værdien er reelt kWh (Codex-review på PR #9 påpeger det samme). Jeg bruger konsistente enheder: kWh i `Measurement`, Wh i dictionaries.
- **Om egmp:** det er ikke en iOS-app, men et mod til Hyundai- og Kia-headunits, der sender data via iAP2 fra bilen (OEM-vejen). Det er derfor irrelevant for bundle-ID-spørgsmålet, men bekræfter dictionary-formatet. De har sænket push-intervallet fra 5 til 10 sekunder, fordi hvert 5. sekund fik Maps til at genberegne ruten konstant. Jeg pusher kun ved ændring (se din regel).

---

## 3. Intents og metoder i evmaps

- **Extensionens `Info.plist`:**
  - `NSExtensionPointIdentifier = com.apple.intents-service`.
  - `IntentsSupported = [INListCarsIntent, INGetCarPowerLevelStatusIntent, INGetCarLockStatusIntent]`. Den sidste har ingen handler.
  - Appen har `INIntentsSupported`. Dokumenttypen `com.apple.maps.directionsrequest` er en rest fra Apples sample.
- **`INExtension.handler(for:)`** router til to handlere.
- **`INListCarsIntentHandling.handle(intent:) async`** returnerer `INCar` med:
  - `carIdentifier` (UUID-streng, ikke VIN), `displayName`, `year`, `make`, `model` og `color`.
  - `headUnit: INCarHeadUnit(bluetoothIdentifier:iAP2Identifier:)`. Det kobler bilen til CarPlay-forbindelsen. evmaps finder værdien via CoreBluetooth ud fra bilens navn. I M0 starter jeg med `nil` og tester derefter med ID.3'ens Bluetooth-ID.
  - `supportedChargingConnectors [.mennekes, .ccs2]` og `setMaximumPower(_:for:)`.
- **`INGetCarPowerLevelStatusIntentHandling`:**
  - **`handle(intent:) async`:** bilen findes via `intent.carName?.vocabularyIdentifier`. Svaret sætter:
    - `carIdentifier` og `dateOfLastStateUpdate` (DateComponents).
    - Begge formula-args.
    - `maximumDistance(Electric)` og `distanceRemaining(Electric)`.
    - `minimum`, `current` og `maximumBatteryCapacity`.
    - `chargePercentRemaining` (0–1) og `charging`.
    - `minutesToFull` og `activeConnector`.
  - **`startSendingUpdates(for:to:)`** sender straks cache via `observer.didUpdate(getCarPowerLevelStatus:)` og derefter MQTT- eller timer-opdateringer (10 min).
  - **`stopSendingUpdates(for:)`** rydder op.
  - Fejlkoder: `.failureRequiringAppLaunch` (401) og `.failure`. Ved fejl falder den tilbage til cache.

---

## 4. Rettelser og verifikation af dine noter

| Note | Status |
|---|---|
| Smartcar som VW-partner i Europa | ✅ Aftalen blev annonceret 30/4-2026, og Europa er dækket ifølge changelog 26/5-2026. Matricen for ID.3 2020+ (skærmbilleder 2026-11-18) viser følgende. **Understøttet ✓:** TractionBattery.StateOfCharge, TractionBattery.Range, Charge.IsCharging, DetailedChargingStatus, IsChargingCableConnected/Latched, ChargeLimits, ChargeTimers, TimeToComplete, ChargingConnectorType, Wattage, ChargeRate, EnergyAdded, Odometer, VIN og kommandoerne start/stop charge. **Ikke understøttet ✗:** **TractionBattery.NominalCapacity**, Voltage, Amperage, FastChargerType, IsFastChargerPresent, ChargerPhases, EstimatedRange, IsHeaterActive og Nickname. Kapaciteten skal derfor komme fra `id3.json`. Den kan kalibreres som `EnergyAdded × η / ΔSoC` under AC-ladning. Smartcar er desuden blevet opkøbt af Everyday Electric (tidligere Renew Home), så der er risiko for ændringer i priser og vilkår. |
| Friskhed 4–5 min kun med webhook, ellers ca. 1 gang i døgnet | ✅ `smartcar.com/docs/help/frequencies` |
| Gratisplan: 1 bil, 0 kommandoer, "limited signals" | ✅ Om webhooks og SoC indgår i gratisplanen, fremgår ikke af pricing-siden (rækkerne er kun ikoner). Det tjekkes i dashboardet. Rate limit: bucket på 120, fyldes med 2/min. |
| Vehicles API v2.0 udfases 1/12-2026 | ✅ Webhooks v3: header `SC-Signature` = HMAC-SHA256(hex) over den rå body, med *Application Management Token* som nøgle. `VERIFY`-challenge skal besvares inden for 15 sekunder. |
| EV-routing i Danmark | ❓ Apple skriver kun "select vehicles and select areas". Indirekte hint: evmaps' forfatter er tjekkisk, og README siger "working just for cars from Europe". Det taler for, at det i hvert fald virker i dele af EU. |
| ASC API kan lave certifikat, device og Ad Hoc-profil | ✅ Det kræver en nøgle med **Admin**-rollen. Wildcard via `POST /v1/bundleIds` er udokumenteret, og jeg prøver ét kald. Selve App Store Connect-posten (`POST /v1/apps`) findes ikke i API'et og skal oprettes manuelt (kun plan A). |
| `gh run watch` | ⚠️ `gh` er kun tilladt til søgning i denne sky-session. Jeg følger byggene via GitHub-MCP'ens Actions-værktøjer (list, get og job-logs), og det giver det samme. |

---

## 5. Valg der afviger fra din skitse (begrundet)

1. **Ingen signeringshemmeligheder i GitHub Secrets.** Jeg kan ikke skrive GitHub Secrets herfra, og en `.p12` i base64 er uhåndterlig at indsætte fra iPad.
   - I stedet ligger `.p12`, adgangskode, profiler og ASC-nøgle som Worker-secrets i Cloudflare.
   - Workflowet henter dem fra et `/ci/signing`-endpoint og autentificerer sig med **GitHub Actions' OIDC-token**. Workeren verificerer JWT'en og tjekker `repository == rpaasch/id3soccarplay` og `ref == refs/heads/main` eller udviklingsgrenen.
   - Du skal ikke oprette en eneste GitHub-secret, og ingen hemmelighed passerer chatten.
2. **Certifikatet laves via API'et.** Jeg genererer nøgle og CSR med `openssl` og opretter certifikatet med `POST /v1/certificates`. Du behøver ikke uploade CSR'en eller sende mig en `.cer`. Den lokale nøgle slettes, når `.p12` er lagt i Workeren.
3. **UDID via egen Profile Service på Workeren.** Du åbner `https://<worker>/udid/<hemmelig-sti>` i Safari og installerer en `.mobileconfig`. iPhone sender selv sin signerede UDID tilbage, og Workeren registrerer den via `POST /v1/devices`.
   - Metoden er troværdig, fordi iOS selv udfylder værdien.
   - Fordelen frem for udid.tech er, at serienummer og IMEI ikke ender hos tredjepart.
   - Tag rationelt stilling til advarslen "Ikke bekræftet" (profilen er usigneret), og slet profilen bagefter.
4. **Hosting:** én Worker med R2 bag sig (`/dl/<hemmelig-sti>/…`) til `.ipa`, `manifest.plist` og installationsside. Det er én tjeneste i stedet for Pages plus Worker.
5. **macOS-minutter:** et privat repo på GitHub Free har 2.000 min/md, og macOS tæller ×10. Det svarer til cirka 200 macOS-minutter, eller 25–35 builds.
   - Jeg cacher SwiftPM, XcodeGen via Homebrew-bottle og DerivedData, og bygger kun ved ændringer under `App/`, `Extension/` og `project.yml`.
   - Alternativ: et offentligt repo giver ubegrænsede minutter. Med OIDC-løsningen ligger der intet hemmeligt i repoet, men valget er dit.

---

## 6. Engangstjekliste (manuelt fra iPad)

Rækkefølgen er vigtig. Hvert punkt slutter med, hvad du skal give mig tilbage. **Send aldrig en hemmelighed i chatten.**

### A. Apple (developer.apple.com og appstoreconnect.apple.com i Safari)
1. **Gør Safari klar:** åbn siderne som "Desktop-websted" (aA-menuen). Portalen virker fint på iPad på den måde.
2. **App Store Connect API-nøgle:** gå til Brugere og adgang → Integrationer → App Store Connect API → *Team Keys* → **+**.
   - Navn: `id3-ci`. Rolle: **Admin**. Admin er nødvendig for certifikater og profiler.
   - Download `.p8`-filen. Det kan kun gøres én gang.
   - → **Giv mig:** Key ID (10 tegn) og Issuer ID (UUID). De er ikke hemmelige.
3. **Læg nøglen i sky-miljøet:** claude.ai → Claude Code → miljøets indstillinger → Environment variables:
   - `ASC_KEY_ID=…` og `ASC_ISSUER_ID=…`.
   - `ASC_PRIVATE_KEY=` med `.p8`-indholdet **på én linje uden linjeskift**: kun base64-teksten mellem `BEGIN`- og `END`-linjerne. Jeg genskaber PEM-formatet.
   - Åbn `.p8` i en teksteditor-app (fx Textastic eller Runestone) og kopiér derfra.
   - Bemærk: miljøvariabler gemmes i klartekst i miljøkonfigurationen. Det er et personligt miljø, men nøglen bør tilbagekaldes, hvis miljøet nogensinde deles.
   - Start derefter en ny besked i denne session. Variablerne indlæses ved næste genstart.
4. **Team ID:** står på developer.apple.com → Membership. → **Giv mig** Team ID'et (10 tegn).
5. **Kun hvis wildcard ikke kan oprettes via API:** Identifiers → **+** → App IDs → App → *Wildcard* `com.porsche.*`.
   - Notér, hvilke capabilities der er grå (deaktiverede). Det er netop svaret på Siri- og App Groups-spørgsmålet.
   - Jeg prøver API'et først og siger til, hvis du skal gøre det her.
6. **Kun plan A, efter jeg har registreret `com.porsche.<unikt>`:** App Store Connect → Apps → **+** → Ny app.
   - Platform iOS, navn "ID3 Maps (privat)", bundle-ID vælges fra listen, SKU `id3maps`.
   - TestFlight → Intern test → opret gruppe og tilføj dig selv.
   - → **Giv mig:** appens Apple ID (talværdi i URL'en).

### B. iPhone
7. **UDID:** først når jeg melder, at Workerens `/udid`-side er klar. Åbn linket i Safari på **iPhonen**, installér profilen (Indstillinger → Profil hentet), og slet den bagefter.
   - Er telefonen allerede registreret i Devices, så sig til. Så springer vi punktet over.
8. **iOS-version og iPhone-model:** → **Giv mig** begge.

### C. Cloudflare
9. **Opret konto:** opret en gratis konto og aktivér **R2**. Det kræver et betalingskort, men 10 GB er gratis.
   - Sørg for, at `workers.dev`-subdomænet er sat (Workers & Pages → oversigt).
10. **API-token:** My Profile → API Tokens → Create Custom Token med disse rettigheder: Account → *Workers Scripts:Edit*, *Workers KV Storage:Edit*, *Workers R2 Storage:Edit* og *Account Settings:Read*.
    - **Indsæt ikke tokenet i chatten.** Jeg beder om det via den sikre credential-formular (proxyen injicerer det i kald til `api.cloudflare.com`).
    - → **Giv mig:** Account ID og `workers.dev`-subdomænet. De er ikke hemmelige.

### D. Smartcar (først i M1, men kontoen kan oprettes nu)
11. **Opret konto og app** på dashboard.smartcar.com. Opret en Application, vælg den nye *Signals/v3*-platform og regionen Europe.
    - Redirect URI tilføjes, når jeg giver dig Workerens URL (`https://<worker>/oauth/callback`).
    - → **Giv mig:** Client ID. Det er ikke hemmeligt.
12. **Hemmeligheder direkte i Cloudflare:** Client Secret og Application Management Token tastes **direkte i Cloudflare** under Workers → `id3` → Settings → Variables and Secrets som `SMARTCAR_CLIENT_SECRET` og `SMARTCAR_AMT`.
    - Det gøres, når jeg har deployet Worker-skelettet. Hemmelighederne passerer hverken mig eller chatten.
13. **Tjek planen i dashboardet:** kan der oprettes en *Webhook*-integration på din plan, og kan signalet `TractionBattery.StateOfCharge` vælges i den? → **Giv mig:** ja/nej og eventuel opgraderingspris.
14. **VW-kontoen:** du skal være primær bruger, og onlinetjenesterne skal være aktive i We Connect / Volkswagen-appen.

### E. Bilen (til M0 og CarPlay-kobling)
15. → **Giv mig:**
    - Årgang, batteri (Pure 52 kWh / Pro 58–59 kWh / Pro S 77–79 kWh) og software-version, hvis du kender den.
    - Bilens Bluetooth-navn som det står i iPhonens Bluetooth-liste.
    - Om du bruger trådløs eller kablet CarPlay.

### F. GitHub
16. Intet at gøre. Repoet `rpaasch/id3soccarplay` er allerede koblet på sessionen, og signeringen hentes via OIDC (se afsnit 5). Beslut dog, om repoet skal være privat (cirka 25–35 builds/md gratis) eller offentligt (ubegrænset).

---

## 7. Efterprøvning: virker app-tricket for andre end forfatteren? (research 2026-11-18)

**Konklusion: ingen uafhængig bekræftelse fundet. Stærke indicier for, at whitelisten er server-side på make/model, ikke på bundle-ID.**

- **Apples udviklerforum (tråd 653328, 2020–2024):** flere udviklere implementerer de samme intents; bilen dukker aldrig op i Maps. Apple kaldte det i okt. 2020 en bug (FB8760513). Opfølgninger i 2021, 2022, 2023 og feb. 2024: "still not working". Ingen succesrapport.
- **Apples udviklerforum (tråd 772132, jan. 2025):** udvikler bygger "aftermarket solution … for any EV", efterlyser virkende formula-argumenter. Intet svar med et virkende eksempel.
- **openautolink #190 (okt. 2026) — vigtigste bevis:** mossyhub fik en opdigtet bil ("OAL Test EV") til at *vises* i Apple Maps, men: *"stopped short of actual battery/EV info because it has explicit car Make/Model fields"* og *"something Apple server side that only certain cars work."* → At vise bilen er muligt; EV-data er gated server-side på **make/model**.
- **evmaps-forks:** kun RangeBridge (juli–aug. 2026) hævder at intents virker, og skriver at app-ID'erne *"intentionally remain Porsche IDs for Apple Maps compatibility"*. Fork-forfatterens egen påstand, uden screenshots eller uafhængig bekræftelse. Har fejlsektion "Maps does not show the vehicle option". De øvrige tre forks tilføjer ingen testrapport.
- **iOS 26/27:** Apple har et privat framework **VirtualGarage**, der håndterer bil-/EV-routing-data. Ikke analyseret færdig.

### Konsekvens for M0 — ny hypotese
Whitelisten rammer sandsynligvis `INCar.make`/`model`, ikke bundle-ID'et. Derfor testes to varianter:
- **Variant A (ærlig):** make/model = Volkswagen / ID.3. Virker kun, hvis VW er på Apples serverliste — næsten sikkert ikke.
- **Variant B (Taycan-maskering):** make/model = Porsche / Taycan, som evmaps. Eneste konfiguration med teoretisk chance. Åbent spørgsmål: bruger Maps så vores ID.3-formula-argumenter, eller Apples egen Taycan-model? Kan **kun** afgøres i bilen.

Revideret skøn for *brugbar* ID.3-routing: 10–15 %. Reserve ved fejl: ABRP i CarPlay med live SoC fra Smartcar-delen (M1), som er genbrugbar uanset udfald.

---

## 8. VirtualGarage-symbolerne (iOS 26/27) — mekanismen bekræftet

Analyse af symboldumps fra `VirtualGarage.framework` (til stede i både iOS 26.5 og 27.0 beta). **Der er ingen hardkodet mærke-/modelliste i binæren; allowlisten loades som en ressource/manifest** (muligvis server-leveret eller opdateret med iOS). Relevante symboler:

- **To separate allowlist-veje:**
  - **Siri (vores vej):** config-nøgler `VirtualGarageConfig_EVRoutingManifestKeyNameForSiriBundleID`, `…ForSiriAllowListedModelIDs`, `…ForSiriAllowlist`.
  - **iAP2 (egmp's vej):** `…ForIApAllowlist`, `…ForIApDenylist`, `…ForIApDenyListedModelID/FirmwareID/Model/Year`.
- **Typer/metoder:** `VGExternalAccessoryModelFilter allowsVehicleWithModelId:firmwareId:year:model:`, `_initializeAllowAndDenylists`, `VGAllowlistPayload`, `VGDenylistEntry`, `_modelIdAllowlist`, `_allowedFormulaIDs`, `_isConnectedVehicleAllowlisted`, `VGOEMApplication initWithBundleIdentifier:allowPlaceholder:error:`, `VGVehicle … manufacturer/model/siriIntentsIdentifier`, `VGDataCoordinator _loadAllOEMVehiclesForApps:`.
- **Knapper:** `VirtualGarageConfig_EVRoutingEnableAllowListing`, `…ResourceNameForAllowAndDenylists`, `…KeyNameForModelID`.

### Konsekvenser (afgør projektets rammer)

1. **Siri-vejen gates på bundle-ID + tilladte model-ID'er samtidig.** Derfor bruger evmaps både `com.porsche.one` og Porsches `model_id` 12582912/12582916. Begge skal matche Apples manifest.
2. **Plan A er død.** Et unikt `com.porsche.<navn>` kommer aldrig på Siri-bundle-ID-allowlisten. **Kun eksakt `com.porsche.one`** har en chance → kun plan B (Ad Hoc). TestFlight og App Store Connect-posten droppes.
3. **Vi skal bruge Porsches model-ID'er**, ikke egne.
4. **Uafklaret (kun M0 i bilen kan svare):**
   - a) Tjekkes kun bundle-ID-**strengen**, eller også kodesignatur/team? Kun strengen → tricket virker. Team → umuligt.
   - b) `_allowedFormulaIDs` antyder, at formlen er bundet til model-ID'et. Bruger Maps så vores ID.3-tal eller Apples egen Taycan-model?
5. **make/model = Porsche/Taycan** i `INCar` (maskering), med ID.3-tal i formula-argumenterne.

Dette forenkler projektet: ingen ASC-app-post, ingen TestFlight, kun Ad Hoc-signering.
