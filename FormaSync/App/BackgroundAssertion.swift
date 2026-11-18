import UIKit

/// Asks iOS for a little extra time when the app goes to background in the middle of a sync,
/// so the current request can finish. On expiry the sync is cancelled; the 12-month history resumes
/// from the last completed month on the next run.
@MainActor
enum BackgroundAssertion {
    private static var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "FormaSync") {
            Task { await HealthSyncEngine.shared.cancelCurrent() }
            BackgroundAssertion.end()
        }
    }

    static func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
