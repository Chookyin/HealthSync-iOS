import Foundation
import UIKit
import HealthKit

/// 手动同步的结果，便于 UI 区分「失败」与「已有同步在进行」。
public enum SyncResult: Equatable, Sendable {
    case success
    case failed(String)
    case alreadySyncing
}

enum SyncOrigin: Sendable {
    case foregroundAutomatic
    case manual
    case shortcut
    case healthKit
    case appRefresh
    case processing

    var allowsAuthorizationRequest: Bool {
        self == .foregroundAutomatic || self == .manual
    }

    var honorsAlwaysFullMode: Bool {
        self == .foregroundAutomatic || self == .manual
    }

    var usesBackgroundOverlap: Bool {
        self == .healthKit || self == .appRefresh || self == .shortcut
    }
}

/// 打开即同步的调度中枢（scenePhase 驱动）。
/// 串行化、防重入：同一时刻只允许一个同步任务执行。
@MainActor
public final class SyncCoordinator {
    public static let shared = SyncCoordinator()

    private let healthService: HealthKitService
    private let networkService: HTTPSyncService
    private let cursorStore: SyncCursorStore
    private let settings: HermesSettings
    private let state: AppState
    private let config: SyncConfig

    /// 防重入标志。
    private var isSyncing = false
    private var activeTask: Task<SyncResult, Never>?
    /// 当前进行中的任务是否为手动同步（用于区分手动与自动/后台任务，避免误报）。
    private var isManualTask = false
    /// 同步当前所处阶段（便于定位失败发生在查询还是上传）。
    private var syncStage: String = "idle"
    /// 单调递增的任务令牌：取消旧任务时，旧任务的 finishSync 不会清掉新任务的锁。
    private var taskToken: UInt64 = 0

    public init(healthService: HealthKitService = HealthKitService(),
                networkService: HTTPSyncService = HTTPSyncService(),
                cursorStore: SyncCursorStore = SyncCursorStore(),
                settings: HermesSettings = .shared,
                state: AppState = AppState.shared,
                config: SyncConfig = .default) {
        self.healthService = healthService
        self.networkService = networkService
        self.cursorStore = cursorStore
        self.settings = settings
        self.state = state
        self.config = config
        let savedCursor = cursorStore.load()
        self.state.lastSyncAt = savedCursor.lastSuccessfulAt ?? savedCursor.lastSyncedAt
    }

    // MARK: - 对外入口

    /// App 激活时调用（自动同步开关控制）。
    public func onAppActivated() {
        guard settings.autoSyncOnActive else { return }
        startSync(fullSync: false, origin: .foregroundAutomatic)
    }

    /// 手动同步。返回值表示任务是否成功启动。
    @discardableResult
    public func syncNow() -> Bool {
        beginManualSync(fullSync: false) != nil
    }

    /// 手动同步（可等待结果）。
    /// 规则：
    /// - 若当前有「手动」同步进行中 → 返回 `.alreadySyncing`（UI 提示"正在同步中"）；
    /// - 若当前有「自动/后台」同步进行中 → 先取消它，再启动本次手动同步（手动优先）；
    /// - 否则直接启动手动同步。
    public func syncNowWithResult() async -> SyncResult {
        guard let task = beginManualSync(fullSync: false) else {
            return .alreadySyncing
        }
        return await task.value
    }

    /// 由 HealthKit 观察器或 BGTaskScheduler 启动同步。
    /// 后台任务不抢占已运行的前台/手动任务；手动任务会优先结束后台任务。
    func syncFromBackground(origin: SyncOrigin,
                            fullSync: Bool = false,
                            types: Set<HealthDataType>? = nil) async -> SyncResult {
        guard let task = beginSync(fullSync: fullSync,
                                   origin: origin,
                                   requestedTypes: types) else {
            return .alreadySyncing
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 查询某类型在 HealthKit 中是否有样本，以及最近一次数据的开始时间与可读值（设置页标注用）。
    public func hasSamples(for type: HealthDataType) async -> (hasData: Bool, latestDate: Date?, latestValue: String?) {
        await healthService.hasSamples(for: type)
    }

    /// 已废弃：数据类型现在默认全量启用，不再按「有样本数据」自动勾选。
    /// 保留空方法以兼容旧调用（已不在启动流程中调用）。
    public func autoEnableTypesWithData() async {
    }

    /// 刷新可公开的授权请求状态。
    /// iOS 不会告诉 App 用户是否真的授予了只读权限，因此这里不把“查询有结果”
    /// 或 `authorizationStatus(for:)` 当作读取授权已授予的证明。
    public func refreshHealthAuthStatus() async {
        let requestedEnabled = settings.requestedHealthTypes
            .intersection(settings.enabledTypes)
        state.healthAuthorizationState = requestedEnabled.isEmpty
            ? .notRequested
            : .requested
    }

    /// 读取用户生物学性别（特征类型，本地读取，不弹窗）。
    public func loadBiologicalSex() async -> HKBiologicalSex {
        await healthService.readBiologicalSex()
    }

    /// 强制全量同步（重置游标）。
    public func forceFullSync() {
        guard prepareForManualTakeover() else { return }
        cursorStore.reset()
        state.lastSyncAt = nil
        _ = beginSync(fullSync: true, origin: .manual)
    }

    /// 请求尚未请求过的新启用类型。HealthKit 请求成功不等于权限一定被授予。
    public func requestAuthIfNeeded() async {
        _ = await ensureHealthAuthorizationRequested()
        await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
    }

    /// 取消当前同步。
    public func cancel() {
        taskToken &+= 1
        let task = activeTask
        activeTask = nil
        isSyncing = false
        isManualTask = false
        task?.cancel()
        state.syncPhase = .idle
    }

    public var isCurrentlySyncing: Bool { isSyncing }

    /// 当前失败阶段描述（仅用于日志诊断）。
    private var syncPhaseLabel: String { syncStage }

    // MARK: - 内部

    @discardableResult
    private func startSync(fullSync: Bool, origin: SyncOrigin) -> Bool {
        beginSync(fullSync: fullSync, origin: origin) != nil
    }

    private func beginManualSync(fullSync: Bool) -> Task<SyncResult, Never>? {
        guard prepareForManualTakeover() else { return nil }
        return beginSync(fullSync: fullSync, origin: .manual)
    }

    /// 手动任务优先；只在后台任务运行时取消它。
    private func prepareForManualTakeover() -> Bool {
        guard isSyncing else { return true }
        guard !isManualTask else { return false }
        activeTask?.cancel()
        activeTask = nil
        isSyncing = false
        isManualTask = false
        return true
    }

    private func beginSync(fullSync: Bool,
                           origin: SyncOrigin,
                           requestedTypes: Set<HealthDataType>? = nil) -> Task<SyncResult, Never>? {
        guard !isSyncing else { return nil }
        isSyncing = true
        isManualTask = origin == .manual
        taskToken &+= 1
        let token = taskToken

        state.resetProgress()
        state.syncPhase = .checkingAuth
        state.lastError = nil
        syncStage = "授权"

        let task = Task { @MainActor [weak self] in
            guard let self else { return SyncResult.failed("内部错误") }
            return await self.performSync(
                fullSync: fullSync,
                origin: origin,
                requestedTypes: requestedTypes,
                token: token
            )
        }
        activeTask = task
        return task
    }

    private func performSync(fullSync: Bool,
                             origin: SyncOrigin,
                             requestedTypes: Set<HealthDataType>?,
                             token: UInt64) async -> SyncResult {
        // 1. 确保用户已经处理过当前启用类型的系统授权请求。
        guard await ensureHealthAuthorizationRequested(
            allowRequest: origin.allowsAuthorizationRequest
        ) else {
            let message = origin.allowsAuthorizationRequest
                ? "健康数据权限请求失败，请在系统设置中检查 HealthSync"
                : "后台同步需要先在 App 内完成健康数据授权"
            finishSync(.failed(message), token: token)
            return .failed(message)
        }

        // 2. 配置校验
        guard let serverAddress = settings.serverAddress,
              !settings.normalizedAPIToken.isEmpty else {
            let message = "请先在设置页配置服务器地址与 Token"
            finishSync(.failed(message), token: token)
            return .failed(message)
        }

        // 2.5 探测服务器可达性（可选自愈已移除，直接同步；失败由重试兜底）

        let enabled = requestedTypes.map {
            $0.intersection(settings.enabledTypes)
        } ?? settings.enabledTypes
        guard !enabled.isEmpty else {
            let message = "未启用任何数据类型"
            finishSync(.failed(message), token: token)
            return .failed(message)
        }

        // 3. 计算查询区间（游标策略）
        var cursor = cursorStore.load()
        let now = Date()

        let mayRunScheduledFullSync = origin != .healthKit && origin != .appRefresh
        let firstFullRequired = mayRunScheduledFullSync
            && settings.syncMode == .fullThenIncremental
            && cursor.completedFullSyncAt == nil
        let requestsAllHistory = fullSync
            || firstFullRequired
            || (origin.honorsAlwaysFullMode && settings.syncMode == .alwaysFull)
        let overlap = origin.usesBackgroundOverlap
            ? min(config.incrementalOverlap, config.backgroundIncrementalOverlap)
            : config.incrementalOverlap
        let startDate = SyncWindowPolicy.startDate(
            requestsAllHistory: requestsAllHistory,
            lastSyncedAt: cursor.lastSyncedAt,
            lookback: settings.lookback,
            overlap: overlap,
            now: now
        )

        // 4. 查询（后台 Task 不阻塞 UI）
        state.syncPhase = .syncing
        state.progress = 0
        syncStage = "查询"

        do {
            Logger.info("开始同步：\(enabled.count) 类型，起点 \(startDate)，来源 \(origin)")
            let safeQueryPageSize = max(1, config.batchSize)
            let safeUploadBatchSize = max(1, config.uploadBatchSize)
            let pageSize = min(safeQueryPageSize, safeUploadBatchSize)
            let buffer = SyncBatchBuffer(batchSize: safeUploadBatchSize)
            let osVersion = UIDevice.current.systemVersion
            let device = SyncPayload.Device(model: deviceModel(),
                                            os: osVersion,
                                            app: "HealthSync/1.0")
            let uploadRetries = settings.retryFailedUploads ? config.maxRetryCount : 0
            let apiToken = settings.normalizedAPIToken

            let totalSamples = try await healthService.fetchPages(
                types: enabled,
                startDate: startDate,
                endDate: now,
                pageSize: pageSize
            ) { [weak self] type, fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.state.syncPhase == .syncing else { return }
                    self.state.currentType = type.displayName
                    self.state.progress = fraction * 0.9
                }
            } handler: { [weak self] page in
                guard let self else { throw CancellationError() }
                self.syncStage = "上传"
                self.state.totalSamples += page.count

                for batch in buffer.split(page) {
                    try Task.checkCancellation()
                    let payload = SyncPayload(
                        device: device,
                        batch: batch,
                        range: SyncPayload.Range(start: startDate, end: now),
                        cursorFingerprint: cursor.dedupFingerprint,
                        fullSync: requestsAllHistory
                    )
                    try await self.networkService.upload(
                        payload: payload,
                        address: serverAddress,
                        token: apiToken,
                        retries: uploadRetries
                    )
                    self.state.uploadedBatches += 1
                }
                self.syncStage = "查询"
            }
            state.totalSamples = totalSamples
            state.progress = 1
            Logger.info("HealthKit 查询与上传完成：\(totalSamples) 条")

            // 5. 更新游标
            cursor.lastSyncedAt = now
            cursor.lastSuccessfulAt = now
            if requestsAllHistory {
                cursor.completedFullSyncAt = now
            }
            cursor.dedupFingerprint = "\(now.timeIntervalSince1970)"
            cursorStore.save(cursor)

            finishSync(.success, token: token)
            BackgroundSyncManager.shared.scheduleBackgroundTasks()
            return .success
        } catch is CancellationError {
            Logger.error("同步被取消（来源：\(origin)）")
            finishSync(.failed("同步已取消"), token: token)
            return .failed("同步已取消")
        } catch {
            let phaseLabel = syncPhaseLabel
            Logger.error("同步失败（阶段：\(phaseLabel)）：\(error.localizedDescription)（来源：\(origin)，启用类型 \(enabled.count) 种，起点 \(startDate)）")
            finishSync(.failed(error.localizedDescription), token: token)
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func ensureHealthAuthorizationRequested(allowRequest: Bool = true) async -> Bool {
        await refreshHealthAuthStatus()
        let pending = settings.enabledTypes
            .subtracting(settings.requestedHealthTypes)
        guard !pending.isEmpty else {
            state.healthAuthorizationState = .requested
            return true
        }
        guard allowRequest else {
            state.healthAuthorizationState = .notRequested
            return false
        }

        let readTypes = Set(pending.compactMap { $0.objectType })
        guard !readTypes.isEmpty else {
            state.healthAuthorizationState = .unavailable
            return false
        }
        do {
            try await healthService.requestReadAuthorization(for: pending)
            settings.markHealthTypesRequested(pending)
            state.healthAuthorizationState = .requested
            await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
            return true
        } catch {
            state.healthAuthorizationState = .unavailable
            return false
        }
    }

    private func finishSync(_ phase: SyncPhase, token: UInt64? = nil) {
        if let token, taskToken != token {
            // 已取消的旧任务不得覆盖新任务的任何状态。
            return
        }
        isSyncing = false
        isManualTask = false
        syncStage = "idle"
        activeTask = nil
        switch phase {
        case .success:
            state.syncPhase = .success
            state.lastSyncAt = Date()
        case .failed(let msg):
            state.syncPhase = .failed(msg)
            state.lastError = msg
        default:
            state.syncPhase = phase
        }
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
