import Foundation
import UIKit

enum ShortcutSyncExecutionMode: Equatable, Sendable {
    case incremental
    case fullHistory
}

/// 快捷指令不能等待完整历史回填，因此全量任务必须交给 BGProcessingTask。
enum ShortcutSyncPolicy {
    static func executionMode(cursor: SyncCursor,
                              syncMode: SyncMode) -> ShortcutSyncExecutionMode {
        if syncMode == .alwaysFull {
            return .fullHistory
        }
        if syncMode == .fullThenIncremental,
           cursor.completedFullSyncAt == nil {
            return .fullHistory
        }
        return .incremental
    }
}

enum ShortcutSyncJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
}

struct ShortcutSyncJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: ShortcutSyncJobState
    var requiresFullHistory: Bool
    var attemptCount: Int
    var sampleCount: Int
    var batchCount: Int
    var lastError: String?

    var isPending: Bool {
        state == .queued || state == .running
    }
}

/// 同步任务状态落盘，进程回收后仍能判断上一次任务是否中断。
final class ShortcutSyncJobStore: @unchecked Sendable {
    private static let maximumStoredJobs = 20

    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = ShortcutSyncJobStore.defaultFileURL(),
         fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func jobs() -> [ShortcutSyncJob] {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    func latestPending() -> ShortcutSyncJob? {
        jobs()
            .filter(\.isPending)
            .max(by: { $0.createdAt < $1.createdAt })
    }

    func insert(_ job: ShortcutSyncJob) {
        lock.lock()
        defer { lock.unlock() }

        var stored = readUnlocked()
        stored.removeAll { $0.id == job.id }
        stored.append(job)
        stored.sort { $0.createdAt < $1.createdAt }
        if stored.count > Self.maximumStoredJobs {
            stored.removeFirst(stored.count - Self.maximumStoredJobs)
        }
        writeUnlocked(stored)
    }

    @discardableResult
    func update(id: UUID,
                mutation: (inout ShortcutSyncJob) -> Void) -> ShortcutSyncJob? {
        lock.lock()
        defer { lock.unlock() }

        var stored = readUnlocked()
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        mutation(&stored[index])
        stored[index].updatedAt = Date()
        writeUnlocked(stored)
        return stored[index]
    }

    func markRunningJobsInterrupted(error: String) {
        lock.lock()
        defer { lock.unlock() }

        var stored = readUnlocked()
        let now = Date()
        var changed = false
        for index in stored.indices where stored[index].state == .running {
            stored[index].state = .queued
            stored[index].updatedAt = now
            stored[index].lastError = error
            changed = true
        }
        if changed {
            writeUnlocked(stored)
        }
    }

    func markPendingFailed(error: String) {
        lock.lock()
        defer { lock.unlock() }

        var stored = readUnlocked()
        let now = Date()
        var changed = false
        for index in stored.indices where stored[index].isPending {
            stored[index].state = .failed
            stored[index].updatedAt = now
            stored[index].lastError = error
            changed = true
        }
        if changed {
            writeUnlocked(stored)
        }
    }

    private static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent(
            "HealthSync",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("shortcut-sync-jobs.json")
    }

    private func readUnlocked() -> [ShortcutSyncJob] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ShortcutSyncJob].self, from: data)
        } catch {
            Logger.error("快捷指令同步任务记录损坏：\(error.localizedDescription)")
            return []
        }
    }

    private func writeUnlocked(_ jobs: [ShortcutSyncJob]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(jobs)
            try data.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        } catch {
            Logger.error("快捷指令同步任务保存失败：\(error.localizedDescription)")
        }
    }
}

enum ShortcutSyncOutcome: Equatable, Sendable {
    case completed(samples: Int, batches: Int, lastSyncAt: Date?)
    case started
    case scheduled
    case alreadyRunning
    case failed(String)
}

/// Shortcuts、Siri 和快捷指令自动化进入同步协调器的统一入口。
@MainActor
final class ShortcutSyncService {
    static let shared = ShortcutSyncService()

    private let settings: HermesSettings
    private let cursorStore: SyncCursorStore
    private let jobStore: ShortcutSyncJobStore
    private let state: AppState
    private let maximumBackgroundAttempts = 3
    private var immediateOperation: Task<Void, Never>?
    private var immediateAssertionID: UIBackgroundTaskIdentifier = .invalid

    init(settings: HermesSettings = .shared,
         cursorStore: SyncCursorStore = SyncCursorStore(),
         jobStore: ShortcutSyncJobStore = ShortcutSyncJobStore(),
         state: AppState = .shared) {
        self.settings = settings
        self.cursorStore = cursorStore
        self.jobStore = jobStore
        self.state = state
    }

    var hasPendingJob: Bool {
        jobStore.latestPending() != nil
    }

    func jobs() -> [ShortcutSyncJob] {
        jobStore.jobs()
    }

    func performShortcutSync() async -> ShortcutSyncOutcome {
        Logger.info("收到快捷指令同步请求")
        guard settings.shortcutsSyncEnabled else {
            return .failed("快捷指令同步未启用，请先在 HealthSync 设置中允许。")
        }
        if let setupError = setupError() {
            return .failed(setupError)
        }
        guard !SyncCoordinator.shared.isCurrentlySyncing else {
            return .alreadyRunning
        }

        if let pending = jobStore.latestPending() {
            requeue(pending, error: "等待下一次后台执行")
            BackgroundSyncManager.shared.scheduleBackgroundTasks()
            return .scheduled
        }

        let executionMode = ShortcutSyncPolicy.executionMode(
            cursor: cursorStore.load(),
            syncMode: settings.syncMode
        )
        switch executionMode {
        case .fullHistory:
            _ = insertJob(requiresFullHistory: true, state: .queued)
        case .incremental:
            _ = insertJob(requiresFullHistory: false, state: .queued)
        }
        // AppIntent 必须在系统时限内返回；真正同步由持久化 BGTask 执行。
        BackgroundSyncManager.shared.scheduleBackgroundTasks()
        return startImmediateBackgroundRun() ? .started : .scheduled
    }

    func claimPendingJobForBackground() -> ShortcutSyncJob? {
        guard settings.shortcutsSyncEnabled else {
            return nil
        }
        if let setupError = setupError() {
            jobStore.markPendingFailed(error: setupError)
            return nil
        }
        guard var job = jobStore.latestPending() else { return nil }

        job.state = .running
        job.attemptCount += 1
        job.lastError = nil
        job.updatedAt = Date()
        jobStore.insert(job)
        return job
    }

    func finishBackgroundJob(id: UUID, result: SyncResult) {
        let job = jobStore.jobs().first { $0.id == id }
        switch result {
        case .success:
            finishJob(id: id, result: result, background: true)
        case .alreadySyncing:
            guard let job else { return }
            requeue(job, error: "已有其他同步任务正在运行")
        case .failed(let message):
            if let job,
               job.attemptCount < maximumBackgroundAttempts {
                requeue(job, error: message)
            } else {
                jobStore.update(id: id) {
                    $0.state = .failed
                    $0.lastError = message
                }
            }
        }
    }

    func recoverInterruptedJobs() {
        guard settings.shortcutsSyncEnabled else {
            jobStore.markPendingFailed(error: "快捷指令同步已在设置中关闭")
            return
        }

        jobStore.markRunningJobsInterrupted(
            error: "上一次后台同步被系统中断，等待恢复"
        )
        if hasPendingJob {
            BackgroundSyncManager.shared.scheduleBackgroundTasks()
        }
    }

    func disablePendingJobs() {
        jobStore.markPendingFailed(error: "快捷指令同步已在设置中关闭")
    }

    private func setupError() -> String? {
        guard settings.serverAddress != nil,
              !settings.normalizedAPIToken.isEmpty else {
            return "请先在 HealthSync 中配置服务器地址与 Token。"
        }
        let enabled = settings.enabledTypes
        guard !enabled.isEmpty else {
            return "请先在 HealthSync 中启用至少一种健康数据类型。"
        }
        let pendingAuthorization = enabled.subtracting(
            settings.requestedHealthTypes
        )
        guard pendingAuthorization.isEmpty else {
            return "请先打开一次 HealthSync 完成健康数据授权。"
        }
        return nil
    }

    /// 快捷指令离开后仍保留一段后台执行时间。首个后台上传启动后，
    /// URLSession 会接管文件传输；若系统提前收回时间，则任务自动回到队列。
    private func startImmediateBackgroundRun() -> Bool {
        guard immediateOperation == nil,
              let job = claimPendingJobForBackground() else {
            return false
        }

        let assertionID = UIApplication.shared.beginBackgroundTask(
            withName: "HealthSync.ShortcutSync"
        ) { [weak self] in
            Task { @MainActor in
                self?.cancelImmediateBackgroundRun()
            }
        }
        guard assertionID != .invalid else {
            Logger.error("快捷指令未获得即时后台执行时间")
            requeue(job, error: "iOS 暂未授予后台执行时间")
            BackgroundSyncManager.shared.scheduleBackgroundTasks()
            return false
        }

        immediateAssertionID = assertionID
        Logger.info("快捷指令已启动即时后台同步，全量任务：\(job.requiresFullHistory)")
        immediateOperation = Task { @MainActor [weak self] in
            let result = await SyncCoordinator.shared.syncFromBackground(
                origin: .shortcut,
                fullSync: job.requiresFullHistory
            )
            guard let self else { return }
            self.finishBackgroundJob(id: job.id, result: result)
            Logger.info("快捷指令后台同步结束：\(result)")
            self.immediateOperation = nil
            self.endImmediateAssertion()
            BackgroundSyncManager.shared.scheduleBackgroundTasks()
        }
        return true
    }

    private func cancelImmediateBackgroundRun() {
        Logger.error("快捷指令即时后台执行时间已用完，转交系统重试")
        immediateOperation?.cancel()
        immediateOperation = nil
        endImmediateAssertion()
        BackgroundSyncManager.shared.scheduleBackgroundTasks()
    }

    private func endImmediateAssertion() {
        guard immediateAssertionID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(immediateAssertionID)
        immediateAssertionID = .invalid
    }

    private func insertJob(requiresFullHistory: Bool,
                           state: ShortcutSyncJobState) -> ShortcutSyncJob {
        let now = Date()
        let job = ShortcutSyncJob(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            state: state,
            requiresFullHistory: requiresFullHistory,
            attemptCount: state == .running ? 1 : 0,
            sampleCount: 0,
            batchCount: 0,
            lastError: nil
        )
        jobStore.insert(job)
        return job
    }

    private func finishJob(id: UUID,
                           result: SyncResult,
                           background: Bool) {
        switch result {
        case .success:
            jobStore.update(id: id) {
                $0.state = .succeeded
                $0.sampleCount = self.state.totalSamples
                $0.batchCount = self.state.uploadedBatches
                $0.lastError = nil
            }
        case .alreadySyncing:
            guard let job = jobStore.jobs().first(where: { $0.id == id }) else {
                return
            }
            if background {
                requeue(job, error: "已有其他同步任务正在运行")
            } else {
                jobStore.update(id: id) {
                    $0.state = .failed
                    $0.lastError = "已有其他同步任务正在运行"
                }
            }
        case .failed(let message):
            if background,
               let job = jobStore.jobs().first(where: { $0.id == id }),
               job.attemptCount < maximumBackgroundAttempts {
                requeue(job, error: message)
            } else {
                jobStore.update(id: id) {
                    $0.state = .failed
                    $0.lastError = message
                }
            }
        }
    }

    private func requeue(_ job: ShortcutSyncJob, error: String) {
        jobStore.update(id: job.id) {
            $0.state = .queued
            $0.lastError = error
        }
    }
}
