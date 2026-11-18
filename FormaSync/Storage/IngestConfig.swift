import Foundation

/// Connection settings for the private Forma ingest endpoint. Stored only in the Keychain.
struct IngestConfig: Equatable {
    var url: String
    var clientId: String
    var clientSecret: String
    var bearer: String

    private enum Account {
        static let url = "url"
        static let clientId = "cf_access_client_id"
        static let clientSecret = "cf_access_client_secret"
        static let bearer = "ingest_bearer"
    }

    var isComplete: Bool {
        guard Self.normalizedURL(url) != nil else { return false }
        return !clientId.isEmpty && !clientSecret.isEmpty && !bearer.isEmpty
    }

    static func load() -> IngestConfig? {
        let savedURL = KeychainStore.get(Account.url)
        guard let config = configurationForSavedCredentials(
            url: savedURL,
            clientId: KeychainStore.get(Account.clientId),
            clientSecret: KeychainStore.get(Account.clientSecret),
            bearer: KeychainStore.get(Account.bearer),
            legacyURL: Bundle.main.object(forInfoDictionaryKey: "FormaLegacyIngestURL") as? String
        ) else { return nil }
        if savedURL == nil {
            // Persist the legacy migration once. If the Keychain is unavailable,
            // keep the existing install working and retry on its next load.
            try? config.save()
        }
        return config
    }

    /// Pure migration decision for saved Keychain values; never used for new input.
    static func configurationForSavedCredentials(url: String?, clientId: String?,
                                                clientSecret: String?, bearer: String?,
                                                legacyURL: String?) -> IngestConfig? {
        guard let id = clientId, let secret = clientSecret, let bearer = bearer,
              let endpoint = url ?? legacyURL else { return nil }
        let config = IngestConfig(url: endpoint, clientId: id, clientSecret: secret, bearer: bearer)
        return config.isComplete ? config : nil
    }

    /// A site root targets the ingest endpoint; explicit paths remain unchanged.
    static func normalizedURL(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.url != nil else { return nil }
        if components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" {
            components.percentEncodedPath = "/api/ingest/health"
            return components.url?.absoluteString
        }
        return value
    }

    func save() throws {
        try KeychainStore.set(url, for: Account.url)
        try KeychainStore.set(clientId, for: Account.clientId)
        try KeychainStore.set(clientSecret, for: Account.clientSecret)
        try KeychainStore.set(bearer, for: Account.bearer)
    }

    static func clear() {
        [Account.url, Account.clientId, Account.clientSecret, Account.bearer].forEach { KeychainStore.delete($0) }
    }

    /// Accepts either a JSON object {"url","client_id","client_secret","bearer"}
    /// (the QR code content) or the KEY=VALUE lines of ingest.env.
    static func parse(_ text: String) -> IngestConfig? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String: String] = [:]
        if let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object {
                if let s = value as? String { values[key.lowercased()] = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        } else {
            for line in trimmed.split(whereSeparator: { $0.isNewline }) {
                let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
                values[parts[0].lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        guard let url = values["url"] ?? values["ingest_url"],
              let url = normalizedURL(url),
              let id = values["client_id"] ?? values["cf_access_client_id"],
              let secret = values["client_secret"] ?? values["cf_access_client_secret"],
              let bearer = values["bearer"] ?? values["ingest_bearer"] else { return nil }
        let config = IngestConfig(url: url, clientId: id, clientSecret: secret, bearer: bearer)
        return config.isComplete ? config : nil
    }
}
