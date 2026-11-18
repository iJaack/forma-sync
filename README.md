[Installa Forma Sync sul tuo iPhone con Xcode — guida passo passo](docs/INSTALL-XCODE.md)

Forma Sync è un'app per iPhone che invia i dati di Salute alla tua dashboard.
Richiede una dashboard self-hosted: segui la [guida del template Forma](https://github.com/iJaack/forma-dashboard-template#readme).

Installazione: [docs/INSTALL-XCODE.md](docs/INSTALL-XCODE.md)

# Forma Sync (iOS) — Salute → dashboard Forma

App SwiftUI per iOS 17+, **nessuna dipendenza esterna**. L'unico compito è inviare i dati di Salute
all'endpoint privato del tuo sito, indicato nella configurazione (formato `forma-sync/2`; il server accetta ancora `forma-sync/1`).

**Versione 2.0** — novità:
- **Storico 12 mesi**: inviato un mese alla volta (dal più recente). Nell'app compare "Storico: mese X/12".
  Riprende da dove era arrivato se l'app viene chiusa, sospesa o se manca la rete. Pulsante **"Reinvia ultimi 12 mesi"**.
- Molti più tipi di dati, inviati in formato generico: il server li salva senza bisogno di modifiche.
- Allenamenti con FC min/media/max, dislivello, bracciate, potenza/velocità di corsa e ciclismo, METs, meteo, indoor
  e, da iOS 18, il **punteggio di sforzo** (quello inserito da te oppure la stima di Apple).

Non scrive nulla in Salute. Non legge percorsi GPS, foto, posizione o cartelle cliniche. La fotocamera serve solo a leggere il QR di configurazione.

## Metriche (chiave server · aggregazione giornaliera)
| Gruppo | Tipi |
|---|---|
| Energia | `active_energy_burned`, `basal_energy_burned` (sum, kcal) |
| Attività | `step_count`, `distance_walking_running` (km), `distance_cycling` (km), `distance_swimming` (m), `swimming_stroke_count`, `flights_climbed`, `apple_exercise_time`, `apple_stand_time`, `apple_move_time`, `time_in_daylight` (min) · `apple_stand_hour` (count, ore in piedi) · `physical_effort` (avg/max) |
| Cuore | `heart_rate` (min/avg/max), `resting_heart_rate`, `walking_heart_rate_average`, `heart_rate_variability_sdnn`, `vo2_max` (ml/kg/min), `heart_rate_recovery_one_minute` (avg) |
| Respiro / temperatura | `respiratory_rate`, `oxygen_saturation` (% avg/min), `body_temperature`, `apple_sleeping_wrist_temperature` (°C) |
| Corpo | `body_mass`, `body_fat_percentage` (%), `lean_body_mass`, `body_mass_index`, `height` (cm) — ultimo valore del giorno |
| Sonno | `sleep_asleep_min`, `sleep_inbed_min`, `sleep_awake_min`, `sleep_core_min`, `sleep_deep_min`, `sleep_rem_min` (per notte); fasi singole come eventi `sleep_analysis` (solo ultimi 14 giorni) |
| Mindfulness | `mindful_minutes` (sum) + eventi `mindful_session` |
| Mobilità | `walking_speed`, `walking_step_length`, `walking_asymmetry_percentage`, `walking_double_support_percentage`, `apple_walking_steadiness`, `stair_ascent_speed`, `stair_descent_speed`, `six_minute_walk_test_distance` |
| Corsa / ciclismo | `running_speed`, `running_power`, `running_stride_length`, `running_vertical_oscillation`, `running_ground_contact_time`, `cycling_speed`, `cycling_power`, `cycling_cadence` |
| Rumore | `environmental_audio_exposure`, `headphone_audio_exposure` (dBA avg/max) |
| Alimentazione | `dietary_energy_consumed`, `dietary_protein`, `dietary_carbohydrates`, `dietary_fat_total`, `dietary_fiber`, `dietary_sugar`, `dietary_water` (ml), `dietary_caffeine` (mg) — solo se un'app li scrive in Salute |

L'elenco è in `FormaSync/Health/MetricCatalog.swift`.
- Per aggiungere un tipo basta una riga lì.
- Per ogni tipo, il calcolo (somma per i cumulativi, media/min/max/ultimo per gli altri) segue lo stile di aggregazione dichiarato da HealthKit, così non si possono chiedere statistiche incompatibili.
- L'unità viene verificata prima della lettura: un tipo con unità errata viene saltato, l'app non va in crash.

**Aggiornando dalla 1.0**: all'apertura compare **"Aggiorna permessi Salute"**. Premilo e attiva le nuove voci.
I tipi senza permesso vengono saltati, senza errori.

## Forma v2

- **2.1.1 (build 4)**: tema scuro più caldo, con accento oro invariato.

## Novità 2.1 (affidabilità e qualità dei dati)

- **Mai più "Sincronizzazione in corso…" bloccata**: ogni lettura da Salute ha un timeout (90 s); se per 3 minuti non c'è
  avanzamento, un controllo la chiude con un errore leggibile. "Sincronizza ora" e "Reinvia ultimi 12 mesi" non vengono più
  ignorati: se una sincronizzazione è ferma la annullano e ripartono; se è attiva la richiesta viene messa in coda.
- **Ripresa automatica**: quando l'iPhone viene sbloccato (dati protetti di nuovo disponibili) o l'app torna in primo piano,
  lo storico in sospeso riparte da solo. Dopo aver concesso i permessi lo storico di 12 mesi parte senza premere il pulsante.
- **Primo avvio**: le cancellazioni non vengono inviate (prima c'erano centinaia di "eliminati" inutili); dati prima, eliminazioni dopo.
- **Sonno**: per ogni notte una sola fonte (Apple Watch, poi WHOOP); campioni sovrapposti contati una volta (profondo > REM >
  core > sonno > sveglio > a letto). Sono ammesse le fonti `com.apple.` e `com.whoop.`, più gli eventuali prefissi
  separati da virgole in `FORMA_EXTRA_SLEEP_SOURCES` nel file locale (spazi ed elementi vuoti ignorati).
  Le altre fonti vengono ignorate.
- **Calorie, passi, distanza, esercizio, piani**: totali giornalieri calcolati solo dalle fonti Apple (Apple Watch e iPhone).
  Salute somma anche i dati scritti da altre app, e un'app ha scritto valori di energia impossibili (fino a 900.000 kcal).
- **Allenamenti**: ora viene inviata l'app di origine, così il server tiene la copia dell'Apple Watch quando WHOOP o un'altra
  app scrive la stessa sessione.

Dopo l'installazione premi una volta **Reinvia ultimi 12 mesi**: corregge lo storico del sonno e delle calorie già inviato.

## Come funziona
- **HKObserverQuery + background delivery**: iOS sveglia l'app quando Salute riceve dati nuovi
  (circa ogni ora per le metriche, subito per allenamenti e sonno).
- **HKAnchoredObjectQuery** con ancore salvate: si inviano solo i giorni toccati da dati nuovi o eliminati.
  Le ancore vengono salvate **solo dopo** un invio riuscito, quindi un errore significa reinvio, mai buchi.
- **HKStatisticsCollectionQuery**: i totali giornalieri sono calcolati sull'iPhone con la stessa
  de-duplicazione di Salute (iPhone + Apple Watch non vengono sommati due volte).
- A ogni invio vengono ricontrollati gli **ultimi 30 giorni**: per i giorni toccati si ricalcolano tutti i tipi.
  Gli allenamenti degli ultimi 3 giorni vengono sempre reinviati, perché sforzo e FC possono arrivare dopo.
- **Storico 12 mesi**: 12 finestre di un mese. Il progresso viene salvato dopo ogni mese.
  - Con l'app aperta si completa tutto, di solito in pochi minuti. Tieni l'app aperta; se va in background iOS concede ancora qualche secondo.
  - In background (BGAppRefresh) si invia al massimo un mese per volta.
  - Ogni richiesta resta piccola (≤ 250 valori), perché il server gira sul piano gratuito di Cloudflare Workers.
- Sonno: una sola sorgente per notte (Apple Watch preferito) per evitare doppi conteggi; la notte vale per il giorno del risveglio.
- Allenamenti eliminati in Salute vengono eliminati anche sul server.
- Rete: retry con backoff (2 s, 5 s, 15 s) su errori di rete/429/5xx; 401/403 non vengono ripetuti e compaiono nello stato.
- Fallback: BGAppRefreshTask (~ogni ora, a discrezione di iOS) + sincronizzazione all'apertura.
- Credenziali (service token Access + bearer) **solo nel Portachiavi**, accessibili dopo il primo sblocco,
  solo su questo dispositivo. Nessun segreto nel codice sorgente.

## Requisiti e installazione con Xcode

Per installare l'app sul tuo Mac e iPhone segui la [guida completa in italiano](docs/INSTALL-XCODE.md):
include account gratuito o a pagamento, firma, Modalità sviluppatore, configurazione e problemi comuni.

- Mac con Xcode recente e iPhone con iOS 17+.
- Un Apple ID: **HealthKit è disponibile anche con Personal Team gratuito** secondo la tabella Apple
  riportata nella guida; il profilo gratuito dura 7 giorni. Non è stato testato su un account gratuito reale.
- Homebrew e XcodeGen (`brew install xcodegen`): il progetto `.xcodeproj` viene generato.

Dalla cartella del codice, per la prima installazione:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# Inserisci il tuo Team ID e un bundle ID unico in Config/Local.xcconfig.
xcodegen generate
open FormaSync.xcodeproj
```

Seleziona lo schema **FormaSync**, il tuo iPhone e il tuo team in **Signing & Capabilities**,
lasciando **Automatically manage signing** attivo, poi premi **▶ Run**.
I valori personali restano in `Config/Local.xcconfig`, ignorato da Git; non modificare `project.yml`.
Senza override, `Config/Signing.xcconfig` usa team vuoto e bundle ID `com.example.formasync`,
versione 2.1.1 (build 5). L'identificativo del task in background segue automaticamente il bundle ID.
Il servizio Portachiavi è `$(FORMA_BUNDLE_ID).ingest`, personalizzabile con `FORMA_KEYCHAIN_SERVICE`.
Per aggiornare un'installazione esistente, conserva team, bundle ID e servizio Portachiavi precedenti nel file locale.
`FORMA_LEGACY_INGEST_URL` è vuoto per impostazione predefinita: solo un URL https valido abilita la migrazione
delle vecchie credenziali senza URL. Un URL già salvato prevale sempre. In xcconfig scrivi gli URL come
`https:/$()/example.com/api/ingest/health`, perché `//` inizia un commento.

### Verifica configurazione

`bash scripts/check-signing-config.sh` richiede che `Config/Local.xcconfig` sia assente: verifica i valori
neutri, poi crea un override fittizio temporaneo, lo verifica e lo rimuove anche in caso di errore.
Con un file locale già presente usa `bash scripts/check-signing-config.sh --local`: non lo modifica e confronta
i valori risolti e l'Info.plist compilato con le variabili d'ambiente opzionali `EXPECT_TEAM`, `EXPECT_BUNDLE_ID`,
`EXPECT_LEGACY_URL`, `EXPECT_SLEEP_SOURCES`, `EXPECT_KEYCHAIN_SERVICE`, `EXPECT_REFRESH_ID`.
Una variabile impostata a stringa vuota richiede un valore vuoto; una variabile non impostata non aggiunge un vincolo.
Entrambe le modalità verificano Debug e Release e compilano senza firma per simulatore, offline.
Stampano soltanto gli identificativi di configurazione, mai credenziali; i log restano in `build/self-install/`.

## 4. Configurazione nell'app (una volta)
L'indirizzo del sito è **obbligatorio**: l'app non ha un sito predefinito. Puoi ospitare la tua dashboard con il
[template Forma per il self-hosting](https://github.com/iJaack/forma-dashboard-template).

Esempio JSON per QR o Incolla:

```json
{"url":"https://tuo-sito.example/api/ingest/health","client_id":"unused","client_secret":"unused","bearer":"<INGEST_SECRET>"}
```

`url` deve usare https. Se inserisci solo la radice del sito (con o senza `/` finale), l'app aggiunge
`/api/ingest/health`; gli altri percorsi restano come sono. Per il formato `KEY=VALUE`, usa `INGEST_URL`
oppure `URL`. Anche `client_id` e `client_secret` sono obbligatori e non possono essere vuoti:
`unused` va bene per server che richiedono solo il bearer. Sostituisci `<INGEST_SECRET>` con il bearer del tuo server.
Le configurazioni già salvate nel Portachiavi continuano a funzionare dopo l'aggiornamento.

1. Apri Forma Sync → **Configura connessione** (o l'ingranaggio).
2. Scegli uno:
   - **Scansiona QR**: crea sul Mac un QR locale con la tua configurazione, come spiegato nella [guida](docs/INSTALL-XCODE.md#creare-un-qr-soltanto-sul-mac), e inquadralo.
   - **Incolla**: copia il contenuto di `ingest.env` (o del JSON di configurazione) e premi Incolla; gli appunti vengono svuotati.
   - Oppure compila a mano i 4 campi.
3. Se compili i campi a mano, premi **Salva nel Portachiavi**. Poi **Prova connessione** → deve dire **Connessione OK: service token e bearer accettati.** (invia una richiesta vuota, nessun dato).
4. Torna indietro → **Consenti accesso a Salute** → attiva tutte le voci → parte il primo invio (30 giorni + storico 12 mesi).
5. Controlla la dashboard → sezione Fonti / Bilancio: i dati Apple compaiono con il badge "dati reali".

Se usi Forma Sync, **disattiva le automazioni di Health Auto Export / Comandi**: la dashboard dà priorità
ai dati di Forma Sync, ma gli allenamenti inviati da due app comparirebbero due volte.

## 5. TestFlight (interno) — facoltativo
1. App Store Connect → Le mie app → **+ Nuova app** (piattaforma iOS, bundle id come sopra, SKU qualsiasi).
2. Xcode → Product → **Archive** (destinazione "Any iOS Device") → Distribute App → **TestFlight & App Store** (o "TestFlight Internal Only").
3. App Store Connect → TestFlight → aggiungi te stesso come **tester interno** → installa da TestFlight sull'iPhone.
4. `ITSAppUsesNonExemptEncryption = false` è già nell'Info.plist (solo HTTPS standard).
5. Nota linee guida: le regole App Store su HealthKit (privacy policy obbligatoria, nessun uso pubblicitario,
   linee guida 5.1.1/5.1.3) contano per la **pubblicazione** sull'App Store. Per uso personale via Xcode o
   TestFlight interno non serve la review; se un giorno la pubblicassi servirebbero privacy policy e review.

## Risoluzione problemi
| Messaggio | Causa |
|---|---|
| "service token Cloudflare Access non valido o scaduto" | Client Id/Secret errati, token scaduto o non autorizzato per la tua applicazione Access |
| "bearer non valido" | Bearer errato |
| "iPhone bloccato: i dati di Salute non sono leggibili" | Normale in background con iPhone bloccato: riprova al prossimo sblocco |
| Nessun aggiornamento in background | Salute → Impostazioni app: verifica permessi; Impostazioni → Generali → Aggiorna app in background attivo; non chiudere l'app dal multitasking |

## Aggiornare dalla 1.0 (Mac già configurato)
1. Copia sul Mac la nuova cartella `forma-sync` al posto della vecchia. Configurazione e Portachiavi restano sull'iPhone.
2. `xcodegen generate` → apri il progetto → Run sullo stesso iPhone, conservando `Config/Local.xcconfig`, team e bundle ID.
3. Nell'app:
   - premi **Aggiorna permessi Salute** e attiva tutto;
   - lo storico parte da solo, e vedi "Storico: mese X/12".
4. Se un mese fallisce (rete, server), il progresso resta fermo a quel mese. Riprova con **Sincronizza ora**.

## Struttura
```
project.yml                     XcodeGen
Config/Signing.xcconfig         firma predefinita + override locale
Config/Local.xcconfig.example   modello da copiare in Local.xcconfig (ignorato da Git)
docs/INSTALL-XCODE.md           installazione personale passo passo
FormaSync/Info.plist            permessi (Salute, fotocamera), background fetch, BGTask id
FormaSync/FormaSync.entitlements HealthKit + background delivery
FormaSync/App/                  App, AppDelegate (BGTask, observer all'avvio)
FormaSync/Health/               MetricCatalog (tipi letti), sync engine (recente + storico 12 mesi), sonno
FormaSync/Network/              payload forma-sync/2 (con suddivisione in blocchi), client con retry/backoff
FormaSync/Storage/              Portachiavi, configurazione, stato
FormaSync/UI/                   stato, impostazioni, scanner QR, tema scuro Forma
```

## Formato inviato (`forma-sync/2`)
```json
{
  "format": "forma-sync/2", "app": "forma-sync-ios/2.0", "tz": "Europe/Rome",
  "quantities": [
    { "type": "vo2_max", "unit": "ml/kg/min", "date": "2026-10-21", "value": 0, "agg": "avg" },
    { "type": "heart_rate", "unit": "bpm", "date": "2026-10-21", "value": 0, "agg": "max" }
  ],
  "events": [
    { "id": "UUID", "type": "sleep_analysis", "value": "asleep_deep", "start": "ISO8601", "end": "ISO8601",
      "day": "2026-10-21", "extra": { "source": "com.apple.health…" } }
  ],
  "workouts": [{ "id": "UUID", "type": "Corsa", "activity": "37", "day": "2026-10-21", "start": "ISO8601", "end": "ISO8601",
    "duration_min": 0, "distance_km": 0, "kcal": 0, "avg_hr": 0, "max_hr": 0, "min_hr": 0, "elevation_m": 0,
    "effort": 0, "effort_estimated": 0, "swim_strokes": 0, "indoor": false,
    "extra": { "running_power_avg": 0, "avg_mets": 0 } }],
  "deleted_workouts": ["UUID"], "deleted_events": ["UUID"]
}
```
- `date` = giorno di calendario locale. Al posto di `date` si possono usare `start`/`end` per valori su un intervallo.
- `agg` ∈ `sum|avg|min|max|last|count|sample`.
- I reinvii sono idempotenti: lo stesso giorno/tipo/aggregazione o allenamento viene aggiornato, non duplicato.
