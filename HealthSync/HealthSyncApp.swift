import SwiftUI

@main
struct HealthSyncApp: App {
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
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SyncCoordinator.shared.onAppActivated()
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
