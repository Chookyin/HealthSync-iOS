import AppIntents
import Foundation

/// 快捷指令入口。系统可在后台启动 App 执行，不主动打开 App 前台界面。
struct SyncHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "同步健康数据"
    static let description = IntentDescription(
        "在后台将 HealthKit 数据传输到已配置的 HealthSync 服务器。"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult
        & ProvidesDialog
        & ReturnsValue<String> {
        let outcome = await ShortcutSyncService.shared.performShortcutSync()
        return .result(
            value: outcome.dialogMessage,
            dialog: IntentDialog(stringLiteral: outcome.dialogMessage)
        )
    }
}

struct HealthSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncHealthIntent(),
            phrases: [
                "用 \(.applicationName) 同步健康数据",
                "让 \(.applicationName) 后台同步健康数据",
            ],
            shortTitle: "同步健康数据",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }

    static let shortcutTileColor = ShortcutTileColor.teal
}

private extension ShortcutSyncOutcome {
    var dialogMessage: String {
        switch self {
        case .completed(let samples, let batches, let lastSyncAt):
            let time = lastSyncAt?.formatted(
                date: .abbreviated,
                time: .shortened
            ) ?? "刚刚"
            return "同步完成：\(samples) 条，\(batches) 批，时间 \(time)。"
        case .started:
            return "后台同步已开始，HealthSync 不需要打开前台。"
        case .scheduled:
            return "已加入 iOS 后台同步队列，HealthSync 不需要打开前台。"
        case .alreadyRunning:
            return "已有同步任务正在运行或等待后台继续。"
        case .failed(let message):
            return message
        }
    }
}
