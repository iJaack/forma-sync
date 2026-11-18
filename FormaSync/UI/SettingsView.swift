import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var status: SyncStatusStore
    @State private var url = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var bearer = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showScanner = false
    @State private var testing = false
    @State private var confirmDelete = false

    private var draft: IngestConfig {
        IngestConfig(url: IngestConfig.normalizedURL(url) ?? url.trimmingCharacters(in: .whitespacesAndNewlines),
                     clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                     clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                     bearer: bearer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Importa") {
                    Text("Scansiona il codice QR di configurazione oppure copia il contenuto di ingest.env e incollalo.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    Text("La configurazione deve includere l'indirizzo del sito (url) in https.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    HStack(spacing: 10) {
                        Button { showScanner = true } label: { Label("Scansiona QR", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { pasteConfig() } label: { Label("Incolla", systemImage: "doc.on.clipboard") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }

                Card(title: "Connessione") {
                    field("URL endpoint", text: $url, secure: false, keyboard: .URL,
                          placeholder: "https://tuo-sito.example/api/ingest/health")
                    field("CF-Access-Client-Id", text: $clientId, secure: false, keyboard: .asciiCapable)
                    field("CF-Access-Client-Secret", text: $clientSecret, secure: true, keyboard: .asciiCapable)
                    field("Bearer", text: $bearer, secure: true, keyboard: .asciiCapable)
                }

                if let message = message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(messageIsError ? Theme.fail : Theme.ok)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 10) {
                    Button("Salva nel Portachiavi") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 8) {
                            if testing { ProgressView().tint(Theme.text) }
                            Text("Prova connessione")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(testing)
                    Button("Rimuovi credenziali", role: .destructive) { confirmDelete = true }
                        .font(.footnote)
                        .foregroundStyle(Theme.fail)
                        .padding(.top, 6)
                }

                Text("Le credenziali sono salvate solo nel Portachiavi di questo iPhone (non sincronizzate con iCloud). La prova di connessione invia una richiesta vuota, senza dati di salute.")
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Impostazioni")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                showScanner = false
                apply(code, source: "QR")
            }
        }
        .confirmationDialog("Rimuovere le credenziali da questo iPhone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Rimuovi", role: .destructive) {
                IngestConfig.clear()
                clientId = ""; clientSecret = ""; bearer = ""; url = ""
                status.refreshConfiguration()
                show("Credenziali rimosse.", error: false)
            }
            Button("Annulla", role: .cancel) {}
        }
        .onAppear { load() }
    }

    private func field(_ label: String, text: Binding<String>, secure: Bool, keyboard: UIKeyboardType,
                       placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.label(10)).foregroundStyle(Theme.dim)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border2, lineWidth: 1))
        }
    }

    private func load() {
        guard let config = IngestConfig.load() else { return }
        url = config.url
        clientId = config.clientId
        clientSecret = config.clientSecret
        bearer = config.bearer
    }

    private func pasteConfig() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            show("Gli appunti sono vuoti.", error: true)
            return
        }
        apply(text, source: "appunti")
        UIPasteboard.general.string = ""   // don't leave secrets on the clipboard
    }

    private func apply(_ text: String, source: String) {
        guard let config = IngestConfig.parse(text) else {
            show("Configurazione non valida (\(source)). Includi l'indirizzo del sito (url) in https, client id, client secret e bearer.", error: true)
            return
        }
        url = config.url
        clientId = config.clientId
        clientSecret = config.clientSecret
        bearer = config.bearer
        save()
    }

    private func save() {
        let config = draft
        guard config.isComplete else {
            show("Compila tutti i campi (URL https, client id, client secret, bearer).", error: true)
            return
        }
        do {
            try config.save()
            status.refreshConfiguration()
            show("Salvato nel Portachiavi.", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func testConnection() async {
        let config = draft
        guard config.isComplete else {
            show("Compila tutti i campi prima della prova.", error: true)
            return
        }
        testing = true
        defer { testing = false }
        let payload = IngestPayload(app: "forma-sync-ios/test", tz: TimeZone.current.identifier)
        do {
            _ = try await IngestClient.post(payload, config: config, maxAttempts: 1)
            show("Connessione OK: service token e bearer accettati.", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}
