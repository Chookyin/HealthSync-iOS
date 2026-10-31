import SwiftUI
import UIKit

@MainActor
final class HealthSyncAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundUploadSession.shared
        BackgroundUploadSession.shared.setRecoveryHandler {
            Task { @MainActor in
                ShortcutSyncService.shared.recoverInterruptedJobs()
            }
        }
        BackgroundSyncManager.shared.registerTaskHandlers()
        ShortcutSyncService.shared.recoverInterruptedJobs()
        Task {
            await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
        }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadSession.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundUploadSession.shared.storeBackgroundEventsCompletion(completionHandler)
    }
}

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(HealthSyncAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = HermesSettings.shared
    // 用共享单例，与 SyncCoordinator 内部状态同源，确保授权/进度刷新到 UI。
    private let state = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(state)
                .preferredColorScheme(settings.colorScheme.scheme)
                .task {
                    // 启动时读取 HealthKit 真实授权状态并刷新 UI（问题 1）。
                    await SyncCoordinator.shared.refreshHealthAuthStatus()
                    await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SyncCoordinator.shared.onAppActivated()
            } else if phase == .background {
                BackgroundSyncManager.shared.scheduleBackgroundTasks()
            }
        }
    }
}

extension AppColorScheme {
    /// 映射为 SwiftUI ColorScheme。
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
