import SwiftUI

@MainActor
struct StatusView: View {
    @EnvironmentObject private var status: SyncStatusStore
    @State private var authError: String?
    @State private var confirmHistory = false
    @State private var needsAuthUpdate = false
    @State private var autoAuthAsked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !status.isConfigured {
                    setupCard(title: "1 · Connessione",
                              text: "Inserisci service token e bearer della tua dashboard Forma. Restano solo nel Portachiavi di questo iPhone.") {
                        NavigationLink("Configura connessione") { SettingsView() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                if !status.healthAuthRequested {
                    setupCard(title: status.isConfigured ? "Accesso a Salute" : "2 · Accesso a Salute",
                              text: "Forma Sync legge (solo lettura) attività, energia, cuore, respiro, temperatura, corpo, sonno, mobilità, corsa, alimentazione e allenamenti. Niente percorsi GPS, niente foto. Non scrive nulla.") {
                        let healthButton = Button("Consenti accesso a Salute") { Task { await requestHealth() } }
                        if status.isConfigured {
                            healthButton.buttonStyle(PrimaryButtonStyle())
                        } else {
                            healthButton.buttonStyle(OutlineButtonStyle())
                        }
                        if let authError = authError {
                            Text(authError).font(.footnote).foregroundStyle(Theme.fail)
                        }
                    }
                }
                if status.healthAuthRequested && needsAuthUpdate {
                    setupCard(title: "Nuovi dati disponibili",
                              text: "Questa versione legge più tipi di dati (VO₂max, SpO₂, respiro, temperatura, mobilità, corsa, alimentazione…). Concedi l’accesso ai nuovi tipi.") {
                        Button("Aggiorna permessi Salute") { Task { await requestHealth() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                stateCard
                historyCard
                lastSendCard
                if let error = status.lastError {
                    Card(title: "Errore") {
                        Text(error).font(.callout).foregroundStyle(Theme.fail)
                        if let at = status.lastErrorAt {
                            Text(at.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.label(10)).foregroundStyle(Theme.dim)
                        }
                    }
                }
                actions
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Impostazioni")
            }
        }
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .confirmationDialog("Reinviare gli ultimi 12 mesi?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Reinvia 12 mesi") { Task { await resendHistory() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Ricalcola e invia di nuovo, mese per mese, valori giornalieri, sonno e allenamenti. I dati sul server vengono aggiornati, non duplicati. Tieni l’app aperta qualche minuto; se la chiudi riprende dal mese a cui era arrivata.")
        }
        .onAppear {
            status.refreshConfiguration()
            Task {
                let needed = await HealthSyncEngine.shared.authorizationNeedsUpdate()
                await MainActor.run { needsAuthUpdate = needed }
                // After an update with new data types: ask once automatically, then start (or resume) the sync.
                if needed && status.healthAuthRequested && !autoAuthAsked {
                    await MainActor.run { autoAuthAsked = true }
                    await requestHealth()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Forma Sync")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("SALUTE → DASHBOARD FORMA")
                .font(Theme.label())
                .tracking(1.4)
                .foregroundStyle(Theme.accent)
        }
        .padding(.top, 8)
    }

    private var stateColor: Color {
        if status.isSyncing { return Theme.accent }
        if status.lastError != nil { return Theme.fail }
        return status.lastSuccess == nil ? Theme.dim : Theme.ok
    }

    private var stateText: String {
        if status.isSyncing { return "Sincronizzazione in corso…" }
        if status.lastError != nil { return "Ultimo tentativo non riuscito" }
        if status.lastSuccess == nil { return "Mai sincronizzato" }
        return status.lastNoChanges ? "Aggiornato · nessun dato nuovo" : "Aggiornato"
    }

    private var stateCard: some View {
        Card(title: "Stato") {
            HStack(spacing: 10) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(stateText).font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if status.isSyncing { ProgressView().tint(Theme.accent) }
            }
            if let success = status.lastSuccess {
                row("Ultima sincronizzazione", "\(success.formatted(.relative(presentation: .named))) · \(success.formatted(date: .omitted, time: .shortened))")
            }
            if !status.lastReason.isEmpty { row("Origine", status.lastReason) }
            row("Invii riusciti (totale)", "\(status.totalPosts)")
        }
    }

    private var historyText: String {
        if status.historyMonth > 0 { return "Storico: mese \(status.historyMonth)/\(status.historyTotal)" }
        if status.historyDone >= status.historyTotal { return "Storico 12 mesi: completato" }
        if status.historyDone == 0 { return "Storico 12 mesi: da inviare" }
        return "Storico: mese \(status.historyDone)/\(status.historyTotal) · riprende alla prossima apertura"
    }

    private var historyCard: some View {
        Card(title: "Storico") {
            HStack(spacing: 10) {
                Text(historyText).font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if status.historyMonth > 0 { ProgressView().tint(Theme.accent) }
            }
            ProgressView(value: Double(min(status.historyDone, status.historyTotal)), total: Double(status.historyTotal))
                .tint(Theme.accent)
            Text("Un mese alla volta, dal più recente. Con l’app aperta va avanti fino alla fine; in background al massimo un mese per volta.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
    }

    private var lastSendCard: some View {
        Card(title: "Ultimo invio con dati") {
            HStack {
                StatTile(label: "GIORNI", value: "\(status.lastDays)")
                StatTile(label: "VALORI", value: "\(status.lastValues)")
                StatTile(label: "ALLENAMENTI", value: "\(status.lastWorkouts)")
            }
            HStack {
                StatTile(label: "EVENTI", value: "\(status.lastEvents)")
                StatTile(label: "ELIMINATI", value: "\(status.lastDeleted)")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await HealthSyncEngine.shared.sync(reason: .manual) }
            } label: {
                Label("Sincronizza ora", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!status.canStartSync)
            .opacity(status.canStartSync ? 1 : 0.45)

            Button("Reinvia ultimi 12 mesi") { confirmHistory = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!status.isReady)
                .opacity(status.isReady ? 1 : 0.45)
        }
    }

    private var footer: some View {
        Text("Si aggiorna da sola quando Salute riceve nuovi dati (circa ogni ora, subito per allenamenti e sonno) e quando apri l’app. Gli ultimi 30 giorni vengono ricontrollati a ogni invio. I dati vanno solo alla tua dashboard privata su Cloudflare.")
            .font(.footnote)
            .foregroundStyle(Theme.dim)
            .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
        }
    }

    private func setupCard<Actions: View>(title: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        Card(title: title) {
            Text(text).font(.callout).foregroundStyle(Theme.muted)
            actions()
        }
    }

    private func resendHistory() async {
        await HealthSyncEngine.shared.resetHistory()
        await MainActor.run { status.historyReset() }
        await HealthSyncEngine.shared.sync(reason: .history)
    }

    private func requestHealth() async {
        do {
            try await HealthSyncEngine.shared.requestAuthorization()
            await MainActor.run {
                status.markHealthAuthRequested()
                needsAuthUpdate = false
            }
            await HealthSyncEngine.shared.startObservers()
            if IngestConfig.load() != nil {
                await HealthSyncEngine.shared.sync(reason: .manual)
            }
        } catch {
            await MainActor.run { authError = error.localizedDescription }
        }
    }
}
