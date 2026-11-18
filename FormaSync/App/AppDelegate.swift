import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskID = Bundle.main.bundleIdentifier.map { $0 + ".refresh" }
        ?? "formasync.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            AppDelegate.handleRefresh(refresh)
        }
        // HealthKit observer queries must be (re)installed at every launch, including
        // background launches triggered by background delivery.
        if UserDefaults.standard.bool(forKey: Keys.healthAuthRequested) {
            Task { await HealthSyncEngine.shared.startObservers() }
        }
        Self.scheduleRefresh()
        return true
    }

    /// Health data becomes readable again after the first unlock: resume the pending sync / 12-month history.
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        guard UserDefaults.standard.bool(forKey: Keys.healthAuthRequested), IngestConfig.load() != nil else { return }
        Task { await HealthSyncEngine.shared.sync(reason: .foreground) }
    }

    /// Fallback in case background delivery is throttled: ask iOS for a refresh roughly every hour.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            await HealthSyncEngine.shared.sync(reason: .backgroundRefresh)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
