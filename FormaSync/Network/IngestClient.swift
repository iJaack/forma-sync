import Foundation

enum SyncError: LocalizedError {
    case notConfigured
    case healthUnavailable
    case healthLocked
    case http(Int, String)
    case network(String)
    case unexpectedResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connessione non configurata: apri Impostazioni."
        case .healthUnavailable: return "Salute non è disponibile su questo dispositivo."
        case .healthLocked: return "iPhone bloccato: i dati di Salute non sono leggibili. Riprovo al prossimo sblocco."
        case .http(let code, let message): return "Errore server \(code): \(message)"
        case .network(let message): return "Rete non disponibile: \(message)"
        case .unexpectedResponse: return "Risposta inattesa dal server (login Cloudflare Access?). Controlla il service token."
        case .timeout: return "Salute non ha risposto in tempo: riprovo."
        }
    }
}

enum IngestClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// POSTs a payload with exponential backoff on network errors, 408, 429 and 5xx.
    /// 4xx errors (wrong token/bearer, bad format) are not retried.
    static func post(_ payload: IngestPayload, config: IngestConfig, maxAttempts: Int = 4) async throws -> IngestResponse {
        guard let url = URL(string: config.url) else { throw SyncError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.clientId, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(config.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("Bearer \(config.bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let delays: [UInt64] = [0, 2, 5, 15, 30]
        var lastError: Error = SyncError.network("nessuna risposta")
        for attempt in 0..<max(1, min(maxAttempts, delays.count)) {
            if delays[attempt] > 0 {
                try await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncError.unexpectedResponse }
                let code = http.statusCode
                if (200..<300).contains(code) {
                    // A 200 from another host means Access redirected us to its login page.
                    guard http.url?.host == url.host,
                          let decoded = try? JSONDecoder().decode(IngestResponse.self, from: data),
                          decoded.ok else { throw SyncError.unexpectedResponse }
                    return decoded
                }
                // Cloudflare Access answers with an HTML page (401/403) when the service token is wrong;
                // the Forma API itself always answers JSON.
                let fromAccess = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html")
                let error = SyncError.http(code, message(for: code, fromAccess: fromAccess))
                if code == 408 || code == 429 || code >= 500 {
                    lastError = error
                    continue
                }
                throw error
            } catch let error as SyncError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = SyncError.network(error.localizedDescription)
            }
        }
        throw lastError
    }

    private static func message(for code: Int, fromAccess: Bool) -> String {
        if fromAccess && (code == 401 || code == 403) {
            return "service token Cloudflare Access non valido o scaduto."
        }
        switch code {
        case 401: return "bearer non valido."
        case 403: return "accesso negato (service token non abbinato a questa app)."
        case 404: return "URL errato."
        case 413: return "invio troppo grande."
        case 422: return "formato non riconosciuto."
        case 429: return "troppe richieste."
        default: return code >= 500 ? "problema temporaneo del server." : "richiesta rifiutata."
        }
    }
}
