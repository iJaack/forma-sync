import Foundation
import SwiftUI

struct SyncSummary: Sendable {
    var days = 0
    var values = 0
    var events = 0
    var workouts = 0
    var deleted = 0
    var posts = 0
    var noChanges = false

    mutating func add(_ other: SyncSummary) {
        guard !other.noChanges else { return }
        days += other.days
        values += other.values
        events += other.events
        workouts += other.workouts
        deleted += other.deleted
        posts += other.posts
        noChanges = false
    }
}

enum SyncReason: String, Sendable {
    case manual, foreground, observer, backgroundRefresh, history

    var label: String {
        switch self {
        case .manual: return "manuale"
        case .foreground: return "apertura app"
        case .observer: return "nuovi dati Salute"
        case .backgroundRefresh: return "background"
        case .history: return "reinvio 12 mesi"
        }
    }
}

/// UI-facing sync status, persisted in UserDefaults (no health data, no secrets).
/// All mutations happen on the main actor.
final class SyncStatusStore: ObservableObject {
    static let shared = SyncStatusStore()

    private struct Persisted: Codable {
        var lastSuccess: Date?
        var lastAttempt: Date?
        var lastError: String?
        var lastErrorAt: Date?
        var lastDays = 0
        var lastWorkouts = 0
        var lastDeleted = 0
        var lastNoChanges = false
        var lastReason = ""
        var totalPosts = 0
        var lastValues: Int?
        var lastEvents: Int?
    }

    /// Never persisted: every launch starts idle, so a run killed by iOS can't leave the UI stuck.
    @Published private(set) var isSyncing = false
    @Published private(set) var lastHeartbeat = Date.distantPast
    private var watchdog: Task<Void, Never>?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorAt: Date?
    @Published private(set) var lastDays = 0
    @Published private(set) var lastWorkouts = 0
    @Published private(set) var lastDeleted = 0
    @Published private(set) var lastNoChanges = false
    @Published private(set) var lastReason = ""
    @Published private(set) var totalPosts = 0
    @Published private(set) var lastValues = 0
    @Published private(set) var lastEvents = 0
    /// Completed months of the 12-month history (0…12) and the month being sent now (1…12, 0 = idle).
    @Published private(set) var historyDone = 0
    @Published private(set) var historyMonth = 0
    let historyTotal = 12
    @Published private(set) var isConfigured = false
    @Published private(set) var healthAuthRequested = false

    var isReady: Bool { isConfigured && healthAuthRequested }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.status),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            lastSuccess = p.lastSuccess; lastAttempt = p.lastAttempt
            lastError = p.lastError; lastErrorAt = p.lastErrorAt
            lastDays = p.lastDays; lastWorkouts = p.lastWorkouts; lastDeleted = p.lastDeleted
            lastNoChanges = p.lastNoChanges; lastReason = p.lastReason; totalPosts = p.totalPosts
            lastValues = p.lastValues ?? 0; lastEvents = p.lastEvents ?? 0
        }
        historyDone = defaults.integer(forKey: Keys.historyDone)
        healthAuthRequested = defaults.bool(forKey: Keys.healthAuthRequested)
        isConfigured = IngestConfig.load() != nil
    }

    private func persist() {
        let p = Persisted(lastSuccess: lastSuccess, lastAttempt: lastAttempt, lastError: lastError,
                          lastErrorAt: lastErrorAt, lastDays: lastDays, lastWorkouts: lastWorkouts,
                          lastDeleted: lastDeleted, lastNoChanges: lastNoChanges, lastReason: lastReason,
                          totalPosts: totalPosts, lastValues: lastValues, lastEvents: lastEvents)
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Keys.status) }
    }

    @MainActor func refreshConfiguration() {
        isConfigured = IngestConfig.load() != nil
        healthAuthRequested = UserDefaults.standard.bool(forKey: Keys.healthAuthRequested)
    }

    @MainActor func markHealthAuthRequested() {
        UserDefaults.standard.set(true, forKey: Keys.healthAuthRequested)
        healthAuthRequested = true
    }

    @MainActor func begin() {
        isSyncing = true
        lastAttempt = Date()
        lastHeartbeat = Date()
        persist()
        startWatchdog()
    }

    @MainActor func heartbeat() {
        lastHeartbeat = Date()
    }

    /// True when a sync shows "in corso" but has made no progress for a while.
    var isStale: Bool {
        isSyncing && Date().timeIntervalSince(lastHeartbeat) > HealthSyncEngine.staleAfter
    }

    /// Buttons stay usable unless a healthy sync is really running.
    var canStartSync: Bool { isReady && (!isSyncing || isStale) }

    /// If a run stops making progress, release the UI (the engine abandons the stuck run on the next request).
    @MainActor private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self = self, self.isSyncing else { return }
                if Date().timeIntervalSince(self.lastHeartbeat) > HealthSyncEngine.staleAfter {
                    self.fail("Sincronizzazione bloccata (nessun progresso da 3 minuti). Premi Sincronizza ora per ripartire.",
                              reason: .manual)
                    return
                }
            }
        }
    }

    @MainActor func finish(_ summary: SyncSummary, reason: SyncReason) {
        isSyncing = false
        watchdog?.cancel()
        lastSuccess = Date()
        lastError = nil
        lastErrorAt = nil
        lastReason = reason.label
        lastNoChanges = summary.noChanges
        if !summary.noChanges {
            lastDays = summary.days
            lastWorkouts = summary.workouts
            lastDeleted = summary.deleted
            lastValues = summary.values
            lastEvents = summary.events
        }
        totalPosts += summary.posts
        persist()
    }

    @MainActor func historyRunning(month: Int, total: Int) {
        historyMonth = month
    }

    @MainActor func historyIdle(done: Int) {
        historyDone = done
        historyMonth = 0
    }

    @MainActor func historyReset() {
        historyDone = 0
        historyMonth = 0
    }

    @MainActor func fail(_ message: String, reason: SyncReason) {
        isSyncing = false
        watchdog?.cancel()
        lastError = message
        lastErrorAt = Date()
        lastReason = reason.label
        persist()
    }
}
