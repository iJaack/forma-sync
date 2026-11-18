# Installare Forma Sync sul proprio iPhone con Xcode

Questa guida ti accompagna dal codice all'app sul tuo iPhone, anche se non sviluppi software.
Servono il tuo Mac, il tuo Apple ID e una dashboard Forma già funzionante.

```text
Codice → Config/Local.xcconfig → XcodeGen → Xcode → iPhone
                                                    ↓
                                           Permessi Salute
                                                    ↓
                                      Connessione alla tua dashboard
                                                    ↓
                                           Sincronizza ora
```

## 1. Cosa serve

- Un Mac con Xcode recente, scaricato dal Mac App Store. Aprilo almeno una volta e completa
  l'installazione dei componenti richiesti, incluso il supporto iOS.
- Un iPhone con **iOS 17 o successivo**, un cavo USB e il codice di sblocco. Dopo il primo
  abbinamento puoi usare il Wi-Fi (Xcode → Window → Devices and Simulators → iPhone → Connect via network).
- Un Apple ID, anche gratuito. Le differenze tra account sono spiegate al punto 5.
- Homebrew già installato seguendo [le istruzioni ufficiali](https://brew.sh/), poi nel Terminale:

  ```bash
  brew install xcodegen
  ```

- Git (Xcode può installare gli strumenti da riga di comando), oppure il pulsante **Download ZIP** di GitHub.
- La tua dashboard: segui prima la [guida del template Forma per il self-hosting](https://github.com/iJaack/forma-dashboard-template#readme).
  L'app invia dati a quella dashboard; non ne crea una.

Il file `FormaSync.xcodeproj` non è nel repository: viene generato con `xcodegen generate`.

## 2. Scaricare il codice e preparare la configurazione locale

Nel Terminale clona il repository pubblico:

```bash
git clone https://github.com/iJaack/forma-sync.git
cd forma-sync
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

In alternativa, apri [il repository pubblico](https://github.com/iJaack/forma-sync) e scegli
**Code → Download ZIP**. Espandi lo ZIP (la cartella può chiamarsi `forma-sync-main`)
e apri il Terminale. Scrivi `cd `
(con uno spazio), trascina la cartella estratta nella finestra e premi Invio. Poi esegui:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` è ignorato da Git e contiene le tue preferenze di firma. Non modificarle
in `project.yml` o nel progetto generato: XcodeGen rigenera quest'ultimo a ogni aggiornamento.

## 3. Inserire il proprio Team ID e un bundle ID unico

1. Apri **Xcode → Settings → Accounts**, premi **+** e aggiungi il tuo Apple ID.
2. Seleziona il tuo account e il team. Il **Team ID** è un codice di 10 caratteri.
   Per un **Personal Team**, cercalo in Xcode nell'elenco **Team** di **Signing & Capabilities**
   (puoi aprire il progetto dopo il punto 4 e poi tornare qui).
   Per un account a pagamento lo trovi anche nella pagina **Membership** del sito Apple Developer.
   Usa il Team ID, non l'indirizzo email e non il nome visualizzato del team.
3. Apri `Config/Local.xcconfig` con un editor di testo e sostituisci entrambi i segnaposto:

   ```xcconfig
   DEVELOPMENT_TEAM = ABCDE12345
   FORMA_BUNDLE_ID = com.tuonome.formasync
   ```

   `ABCDE12345` va sostituito con il tuo Team ID. Scegli un identificativo come
   `com.<nome>.formasync`, sostituendo anche `<nome>` (senza parentesi, spazi o accenti).
   **Deve essere unico presso Apple**: se Xcode dice che è già occupato, aggiungi qualcosa di tuo.

I valori condivisi restano in `Config/Signing.xcconfig`; quelli locali prevalgono automaticamente.
I test e l'attività di aggiornamento in background seguono il nuovo bundle ID.
Per aggiornare in seguito la stessa installazione, conserva team e bundle ID: cambiarli crea
un'identità diversa e può impedire l'accesso ai dati e alla configurazione precedenti.

### Verifica configurazione

Senza `Config/Local.xcconfig`, esegui `bash scripts/check-signing-config.sh`: controlla i valori neutri,
crea e verifica un override fittizio temporaneo, poi lo elimina anche in caso di errore.
Se il file locale esiste già, usa `bash scripts/check-signing-config.sh --local`: lo conserva e verifica
le impostazioni risolte e l'Info.plist compilato. Puoi fornire i valori attesi con le variabili d'ambiente
opzionali `EXPECT_TEAM`, `EXPECT_BUNDLE_ID`, `EXPECT_LEGACY_URL`, `EXPECT_SLEEP_SOURCES`,
`EXPECT_KEYCHAIN_SERVICE`, `EXPECT_REFRESH_ID` (anche vuote; se assenti non aggiungono vincoli).
Entrambe le modalità controllano Debug e Release e compilano offline, senza firma, solo per simulatore.
L'output contiene solo identificativi non segreti; i log rimangono in `build/self-install/`.
Il modello `Config/Local.xcconfig.example` documenta anche la migrazione URL (`FORMA_LEGACY_INGEST_URL`),
le fonti sonno aggiuntive (`FORMA_EXTRA_SLEEP_SOURCES`) e il servizio Portachiavi (`FORMA_KEYCHAIN_SERVICE`).
Per aggiornare la stessa app conserva anche il precedente servizio Portachiavi. Gli URL in xcconfig vanno
scritti come `https:/$()/example.com/api/ingest/health`, perché `//` inizia un commento.

## 4. Generare il progetto e scegliere l'iPhone

Dalla cartella del codice:

```bash
xcodegen generate
open FormaSync.xcodeproj
```

1. Collega l'iPhone al Mac, sbloccalo e accetta **Autorizza questo computer** se richiesto.
2. In alto in Xcode scegli lo schema **FormaSync**, poi **il tuo iPhone** come destinazione.
3. Nella barra laterale seleziona il progetto **FormaSync**, poi il target **FormaSync** e
   **Signing & Capabilities**. Verifica che **Team** sia il tuo e che non ci siano errori.
   Lascia **Automatically manage signing** attivo.
4. La capability **HealthKit**, con **Background Delivery**, è già negli entitlements.
   È già configurato anche **Background Modes → Background fetch**.
   Non aggiungere certificati o profili al repository.

## 5. Account gratuito o Apple Developer Program?

| | Apple ID gratuito (Personal Team) | Apple Developer Program (99 USD/anno; prezzo locale secondo Apple) |
|---|---|---|
| Durata del profilo di sviluppo | 7 giorni | 1 anno |
| Alla scadenza | L'app smette di aprirsi: collega l'iPhone e premi di nuovo ▶ in Xcode | Esegui nuovamente da Xcode prima della scadenza |
| App con provisioning gratuito sul dispositivo | Massimo 3 contemporaneamente | Nessun limite di 3 app del provisioning gratuito |
| Nuovi App ID | Massimo 10 ogni 7 giorni | Non si applica questo limite del Personal Team |
| HealthKit | Disponibile, inclusa Background Delivery nell'entitlement HealthKit | Disponibile |

La disponibilità di HealthKit per account gratuiti è indicata nella tabella Apple
[Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios).
Stato riportato dalla specifica di questa guida: **«verificato sulla tabella Apple a novembre 2026;
non testato su un account gratuito reale»**. La redazione e la validazione di questa modifica sono
avvenute offline: la tabella e le regole Apple non sono state ricontrollate dal vivo in questa sessione.

Reinstallando sopra la stessa app, con lo stesso team e bundle ID, i dati e la configurazione
salvata **di solito si conservano**. Non è una garanzia di backup: eliminare l'app rimuove i suoi
dati locali; non fare affidamento sulla persistenza del Portachiavi dopo una cancellazione.

La consegna in background e l'aggiornamento periodico sono **best-effort**: decide iOS quando
eseguirli. Un'app scaduta **non sincronizza affatto**, neppure in background.

## 6. Abilitare Modalità sviluppatore e autorizzare lo sviluppatore

1. Dopo aver collegato almeno una volta l'iPhone a Xcode, apri sull'iPhone
   **Impostazioni → Privacy e sicurezza → Modalità sviluppatore**.
2. Attivala, riavvia quando richiesto, poi conferma l'attivazione dopo il riavvio.
   Se la voce manca, torna in Xcode, seleziona l'iPhone e attendi la preparazione del dispositivo.
3. Dopo la prima installazione, se iOS chiede di autorizzare lo sviluppatore (in particolare con
   account gratuiti), vai in **Impostazioni → Generali → VPN e gestione dispositivi**, seleziona
   il profilo dello sviluppatore e conferma che ti fidi. Segui eventuali richieste aggiuntive di iOS.

## 7. Avviare l'app e consentire l'accesso a Salute

In Xcode premi **▶ Run** (oppure **⌘R**). Attendi compilazione, installazione e apertura di **Forma Sync**.
Al primo avvio premi **Consenti accesso a Salute** e consenti le categorie che vuoi sincronizzare;
se la richiesta compare automaticamente, completala. Se prima vuoi preparare la connessione,
segui il punto 8 e torna a questo pulsante.

Puoi modificare le autorizzazioni in seguito in **Salute → Profilo → App → Forma Sync**
(in alcune versioni di iOS la sezione è **App e servizi**). L'app legge soltanto: non scrive in Salute.
Dopo un aggiornamento, il pulsante può essere **Aggiorna permessi Salute**.

## 8. Collegare la propria dashboard

Il server deve avere `INGEST_SECRET` configurato: nella cartella del progetto **della dashboard**
si imposta con `wrangler secret put INGEST_SECRET`, seguendo la
[guida self-host](https://github.com/iJaack/forma-dashboard-template#readme).
Usa nell'app esattamente il valore impostato sul tuo server; non crearne un secondo diverso.

Nell'app premi **Configura connessione**, oppure l'ingranaggio **Impostazioni**.
Puoi importare con **Incolla** o **Scansiona QR** questo formato JSON, sostituendo i segnaposto:

```json
{"url":"https://<tuo-sito>/api/ingest/health","client_id":"unused","client_secret":"unused","bearer":"<INGEST_SECRET>"}
```

- `url` è obbligatorio e deve usare **https**. Anche la sola radice del sito è accettata:
  l'app aggiunge `/api/ingest/health`. Un percorso esplicito diverso viene conservato.
- `client_id` e `client_secret` devono essere presenti e non vuoti. `unused` va bene quando
  la dashboard richiede soltanto il bearer.
- `bearer` è il tuo `INGEST_SECRET`, senza le parentesi `< >`.
- Se hai attivato **Cloudflare Access** davanti al server, sostituisci `unused` con i veri
  valori del service token autorizzato per quella applicazione Access.

Con **Incolla** e **Scansiona QR** la configurazione valida viene salvata automaticamente.
Se compili i campi **URL endpoint**, **CF-Access-Client-Id**, **CF-Access-Client-Secret**, **Bearer**
a mano, premi **Salva nel Portachiavi**. Il messaggio è **Salvato nel Portachiavi.**
Poi premi **Prova connessione**: il risultato atteso è
**Connessione OK: service token e bearer accettati.** La prova invia una richiesta vuota, senza dati Salute.

### Creare un QR soltanto sul Mac

Non usare generatori QR online: la configurazione contiene un segreto. Nel Terminale, nella
cartella di Forma Sync, puoi usare `qrencode` e un file locale protetto:

```bash
brew install qrencode
umask 077
mkdir -p secrets
nano secrets/forma-sync-config.json
```

Nell'editor inserisci il JSON con i tuoi valori. Con nano salva con **Ctrl+O**, Invio, poi esci
con **Ctrl+X**. Non digitare il segreto come argomento di un comando: rimarrebbe nella cronologia.

```bash
qrencode -r secrets/forma-sync-config.json -o secrets/forma-sync-config-qr.png
open secrets/forma-sync-config-qr.png
```

Premi **Scansiona QR** nell'app e inquadra l'immagine. Dopo il salvataggio, chiudi l'anteprima
e cancella entrambi i file:

```bash
rm secrets/forma-sync-config.json secrets/forma-sync-config-qr.png
```

La cartella `secrets/` è ignorata da Git. Non condividere JSON, QR o segreto in chat, screenshot,
repository o servizi di sincronizzazione. Se usi **Incolla**, l'app svuota gli appunti dopo l'importazione;
evita comunque di copiare il segreto con strumenti che conservano la cronologia degli appunti.

## 9. Fare una sincronizzazione di prova

1. Dopo un riavvio, **sblocca l'iPhone almeno una volta**: prima di quel momento i dati Salute
   e la configurazione protetta non sono disponibili. Per la prova tienilo sbloccato e l'app aperta.
2. Torna alla schermata principale e premi **Sincronizza ora**.
3. Lo **Stato** passa a **Sincronizzazione in corso…**, poi a **Aggiornato** oppure
   **Aggiornato · nessun dato nuovo**. **Ultima sincronizzazione** si aggiorna; se ci sono invii,
   aumenta **Invii riusciti (totale)**. In **Ultimo invio con dati** compaiono i conteggi.
4. Al primo collegamento parte anche lo storico: **Storico: mese X/12**, poi
   **Storico 12 mesi: completato**. Lascia aperta l'app; può richiedere qualche minuto.
5. Accedi alla **tua dashboard** e controlla giorni e allenamenti recenti. Puoi anche aprire
   `https://<tuo-sito>/api/data` nel browser **dopo aver effettuato il login**: cerca dati che sai
   essere presenti in Salute. Non usare il bearer di ingest come sostituto del login della dashboard.

Se devi ricalcolare tutto, premi **Reinvia ultimi 12 mesi** e conferma **Reinvia 12 mesi**.
I dati vengono aggiornati, non duplicati. Se l'iPhone non contiene dati autorizzati, una connessione
riuscita può comunque non produrre nuovi valori.

## 10. Risoluzione dei problemi

| Problema | Cosa controllare |
|---|---|
| Team non selezionato / errore di firma | Aggiungi l'Apple ID in Xcode → Settings → Accounts; correggi `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`. In Signing & Capabilities scegli il tuo team e lascia Automatically manage signing attivo. |
| Bundle ID occupato / “Failed to register bundle identifier” | Scegli un `FORMA_BUNDLE_ID` unico; verifica anche team e sessione Apple ID. Rigenera con `xcodegen generate` e riapri il progetto. |
| “Untrusted Developer” / sviluppatore non autorizzato | iPhone → Impostazioni → Generali → VPN e gestione dispositivi → autorizza il tuo sviluppatore. |
| Modalità sviluppatore assente | Collega e sblocca l'iPhone, autorizza il computer, selezionalo in Xcode e attendi la preparazione. Riapri Privacy e sicurezza. |
| L'app non si apre più dopo 7 giorni | Con account gratuito è scaduto il profilo: esegui nuovamente ▶ da Xcode con lo stesso team e bundle ID. Evita di eliminare prima l'app. |
| Permesso HealthKit negato / nessun dato Salute | Salute → Profilo → App → Forma Sync: abilita le categorie. Controlla che quei dati esistano davvero nell'app Salute. iOS non comunica all'app quali permessi di lettura hai negato. |
| Errore server 401 / “bearer non valido.” | Il campo Bearer deve coincidere con `INGEST_SECRET` della tua dashboard. Salva e riprova. Se la risposta proviene da Access, controlla anche il service token. |
| Errore server 403 / service token Cloudflare Access non valido | Access è attivo sul server: servono CF-Access-Client-Id e CF-Access-Client-Secret reali, validi e autorizzati per quell'applicazione; `unused` non basta. |
| Errore server 404 / “URL errato.” | Controlla dominio e percorso `/api/ingest/health`. La radice del sito è normalizzata, un percorso errato esplicito no. |
| Errore server 503 | Controlla nella dashboard che `INGEST_SECRET` sia stato impostato con `wrangler secret put INGEST_SECRET`; poi verifica lo stato del server. L'app mostra un messaggio generico per gli errori 5xx. |
| Errori TLS / HTTPS | Usa `https://`, un certificato valido e il dominio corretto; controlla rete e data/ora dell'iPhone. Non disabilitare la verifica TLS. |
| “Configurazione non valida (appunti). Includi l'indirizzo del sito (url) in https, client id, client secret e bearer.” (oppure origine “QR”) | Controlla JSON, URL https obbligatorio e tutti e tre i campi credenziali non vuoti. Se compili a mano, il messaggio può essere “Compila tutti i campi (URL https, client id, client secret, bearer).” |
| Nessun dato dopo la sincronizzazione | Controlla permessi, dati presenti, connessione e dashboard corretta; sblocca l'iPhone dopo il riavvio e riprova con Sincronizza ora tenendo l'app aperta. |
| Nessun aggiornamento in background | iOS decide quando concederlo. Controlla Aggiorna app in background nelle impostazioni, evita di chiudere forzatamente l'app e prova in primo piano. Controlla anche che il profilo non sia scaduto. |

## 11. Aggiornare l'app

Se hai usato Git, dalla cartella del codice:

```bash
git pull
xcodegen generate
open FormaSync.xcodeproj
```

`Config/Local.xcconfig` resta locale e non viene sostituito da Git. Con un nuovo ZIP, conserva
una copia di quel file e rimettila nella cartella `Config/` della nuova versione prima di generare
il progetto. **Non eseguire di nuovo `cp ...example ...Local.xcconfig` sopra il tuo file personalizzato.**

Seleziona ancora **FormaSync** e lo stesso iPhone, poi premi **▶**. Mantieni lo stesso team e
bundle ID per aggiornare l'app esistente; se compare **Aggiorna permessi Salute**, completa la richiesta.
