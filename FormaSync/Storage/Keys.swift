import Foundation

/// UserDefaults keys (never secrets: those live only in the Keychain).
enum Keys {
    static let healthAuthRequested = "auth.requested"
    static let authorizationVersion = "auth.version"
    static let recentFormat = "sync.recentFormat"
    static let historyDone = "sync.history.monthsDone"
    static let status = "sync.status.v1"
}
