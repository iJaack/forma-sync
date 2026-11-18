import SwiftUI

@main
struct FormaSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(SyncStatusStore.shared)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var status: SyncStatusStore

    var body: some View {
        NavigationStack {
            StatusView()
        }
        .tint(Theme.accent)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if status.isReady {
                    Task { await HealthSyncEngine.shared.sync(reason: .foreground) }
                }
            case .background:
                AppDelegate.scheduleRefresh()
            default:
                break
            }
        }
    }
}
