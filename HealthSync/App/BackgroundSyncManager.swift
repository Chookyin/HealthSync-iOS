import BackgroundTasks
import Foundation

/// 统一协调 HealthKit 后台投递、短期刷新和长任务回填。
@MainActor
final class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()

    static let refreshTaskIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.example.HealthSync").background-refresh"
    static let processingTaskIdentifier = "\(Bundle.main.bundleIdentifier ?? "com.example.HealthSync").background-processing"

    private let settings: HermesSettings
    private let cursorStore: SyncCursorStore
    private let healthDelivery: HealthKitBackgroundDelivery
    private var hasRegisteredHandlers = false
    private var configurationTask: Task<Void, Never>?
    private var configurationRevision = 0

    init(settings: HermesSettings = .shared,
         cursorStore: SyncCursorStore = SyncCursorStore(),
         healthDelivery: HealthKitBackgroundDelivery = HealthKitBackgroundDelivery()) {
        self.settings = settings
        self.cursorStore = cursorStore
        self.healthDelivery = healthDelivery
    }

    /// 必须在 applicationDidFinishLaunching 返回前调用。
    func registerTaskHandlers() {
        guard !hasRegisteredHandlers else { return }
        hasRegisteredHandlers = true

        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleRefreshTask(refreshTask)
            }
        }
        if !refreshRegistered {
            Logger.error("后台刷新任务注册失败：\(Self.refreshTaskIdentifier)")
        }

        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleProcessingTask(processingTask)
            }
        }
        if !processingRegistered {
            Logger.error("后台处理任务注册失败：\(Self.processingTaskIdentifier)")
        }
    }

    /// 在启动、配置变化或回到前台后重建订阅并排上下一次后台任务。
    func refreshBackgroundConfiguration() async {
        configurationRevision &+= 1
        let revision = configurationRevision
        let previousTask = configurationTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            await self?.applyBackgroundConfiguration()
        }
        configurationTask = task
        await task.value
        if revision == configurationRevision {
            configurationTask = nil
        }
    }

    func scheduleBackgroundTasks() {
        let configurationReady = settings.serverAddress != nil
            && !settings.normalizedAPIToken.isEmpty
        let regularBackgroundReady = settings.backgroundSyncEnabled
            && configurationReady
        let shortcutBackgroundReady = settings.shortcutsSyncEnabled
            && configurationReady
            && ShortcutSyncService.shared.hasPendingJob

        if shortcutBackgroundReady {
            cancelRefreshTask()
            scheduleRefreshTask(earliestDelay: 5 * 60)
        } else if regularBackgroundReady {
            scheduleRefreshTask(earliestDelay: 30 * 60)
        } else {
            cancelRefreshTask()
        }

        scheduleProcessingTaskIfNeeded()
    }

    func backgroundSyncDidFinish(_ result: SyncResult,
                                 shortcutJobID: UUID? = nil) {
        if let shortcutJobID {
            ShortcutSyncService.shared.finishBackgroundJob(
                id: shortcutJobID,
                result: result
            )
        }
        scheduleBackgroundTasks()
        if case .failed(let message) = result {
            Logger.error("后台同步未完成：\(message)")
        }
    }

    func disableBackgroundWork() async {
        await refreshBackgroundConfiguration()
    }

    private func applyBackgroundConfiguration() async {
        guard settings.backgroundSyncEnabled else {
            await healthDelivery.stop()
            scheduleBackgroundTasks()
            return
        }

        guard settings.serverAddress != nil,
              !settings.normalizedAPIToken.isEmpty else {
            await healthDelivery.stop()
            scheduleBackgroundTasks()
            return
        }

        let types = settings.enabledTypes.intersection(settings.requestedHealthTypes)
        guard !types.isEmpty else {
            await healthDelivery.stop()
            scheduleBackgroundTasks()
            return
        }

        do {
            try await healthDelivery.start(types: types) { [weak self] changedTypes in
                let result = await SyncCoordinator.shared.syncFromBackground(
                    origin: .healthKit,
                    types: changedTypes
                )
                await self?.backgroundSyncDidFinish(result)
            }
        } catch {
            Logger.error("HealthKit 后台投递配置失败：\(error.localizedDescription)")
        }

        scheduleBackgroundTasks()
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        scheduleRefreshTask(earliestDelay: 30 * 60)
        if let job = ShortcutSyncService.shared.claimPendingJobForBackground() {
            runBackgroundTask(
                task,
                origin: .shortcut,
                fullSync: job.requiresFullHistory,
                shortcutJobID: job.id
            )
            return
        }
        runBackgroundTask(task, origin: .appRefresh)
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        if let job = ShortcutSyncService.shared.claimPendingJobForBackground() {
            runBackgroundTask(
                task,
                origin: .shortcut,
                fullSync: job.requiresFullHistory,
                shortcutJobID: job.id
            )
            return
        }

        let cursor = cursorStore.load()
        let needsFullHistory = BackgroundSyncPolicy.needsInitialFullSync(
            cursor: cursor,
            mode: settings.syncMode
        )
        runBackgroundTask(
            task,
            origin: .processing,
            fullSync: needsFullHistory
        )
    }

    private func runBackgroundTask(_ task: BGTask,
                                   origin: SyncOrigin,
                                   fullSync: Bool = false,
                                   shortcutJobID: UUID? = nil) {
        let shortcutEnabled = settings.shortcutsSyncEnabled
        let regularBackgroundEnabled = settings.backgroundSyncEnabled
        let originEnabled = origin == .shortcut
            ? shortcutEnabled
            : regularBackgroundEnabled
        guard originEnabled,
              settings.serverAddress != nil,
              !settings.normalizedAPIToken.isEmpty else {
            if let shortcutJobID {
                ShortcutSyncService.shared.finishBackgroundJob(
                    id: shortcutJobID,
                    result: .failed("后台同步配置不可用")
                )
            }
            task.setTaskCompleted(success: false)
            scheduleBackgroundTasks()
            return
        }

        let operation = Task { @MainActor in
            await SyncCoordinator.shared.syncFromBackground(
                origin: origin,
                fullSync: fullSync
            )
        }
        task.expirationHandler = {
            operation.cancel()
        }

        Task { @MainActor [weak self] in
            let result = await operation.value
            let completed = result == .success || result == .alreadySyncing
            task.setTaskCompleted(success: completed)
            self?.backgroundSyncDidFinish(
                result,
                shortcutJobID: shortcutJobID
            )
        }
    }

    private func scheduleRefreshTask(earliestDelay: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: earliestDelay
        )
        submit(request)
    }

    private func scheduleProcessingTaskIfNeeded() {
        let cursor = cursorStore.load()
        let configurationReady = settings.serverAddress != nil
            && !settings.normalizedAPIToken.isEmpty
        let shortcutJob = settings.shortcutsSyncEnabled && configurationReady
            ? ShortcutSyncService.shared.jobs().first(where: \.isPending)
            : nil
        let needsRegularFullHistory = settings.backgroundSyncEnabled
            && configurationReady
            && BackgroundSyncPolicy.needsInitialFullSync(
            cursor: cursor,
            mode: settings.syncMode
        )
        guard shortcutJob != nil || needsRegularFullHistory else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: Self.processingTaskIdentifier
            )
            return
        }

        if shortcutJob != nil {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: Self.processingTaskIdentifier
            )
        }
        let request = BGProcessingTaskRequest(
            identifier: Self.processingTaskIdentifier
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = shortcutJob == nil
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: shortcutJob == nil ? 2 * 60 * 60 : 60
        )
        submit(request)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger.debug("后台任务暂未排期：\(request.identifier)，\(error.localizedDescription)")
        }
    }

    private func cancelRefreshTask() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: Self.refreshTaskIdentifier
        )
    }

}

enum BackgroundSyncPolicy {
    static func needsInitialFullSync(cursor: SyncCursor, mode: SyncMode) -> Bool {
        guard mode == .fullThenIncremental else { return false }
        return cursor.completedFullSyncAt == nil
    }
}
