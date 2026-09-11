import Foundation
import UIKit
import HealthKit

/// 手动同步的结果，便于 UI 区分「失败」与「已有同步在进行」。
public enum SyncResult: Equatable {
    case success
    case failed(String)
    case alreadySyncing
}

/// 打开即同步的调度中枢（scenePhase 驱动）。
/// 串行化、防重入：同一时刻只允许一个同步任务执行。
public final class SyncCoordinator: @unchecked Sendable {
    public static let shared = SyncCoordinator()

    private let healthService: HealthKitService
    private let networkService: HTTPSyncService
    private let cursorStore: SyncCursorStore
    private let settings: HermesSettings
    private let state: AppState
    private let config: SyncConfig

    /// 防重入标志。
    private var isSyncing = false
    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?
    /// 当前进行中的任务是否为手动同步（用于区分手动与自动/后台任务，避免误报）。
    private var isManualTask = false
    /// 同步当前所处阶段（便于定位失败发生在查询还是上传）。
    private var syncStage: String = "idle"
    /// 单调递增的任务令牌：取消旧任务时，旧任务的 finishSync 不会清掉新任务的锁。
    private var taskToken: UInt64 = 0

    public init(healthService: HealthKitService = HealthKitService(),
                networkService: HTTPSyncService = HTTPSyncService(),
                cursorStore: SyncCursorStore = SyncCursorStore(),
                settings: HermesSettings = HermesSettings(),
                state: AppState = AppState.shared,
                config: SyncConfig = .default) {
        self.healthService = healthService
        self.networkService = networkService
        self.cursorStore = cursorStore
        self.settings = settings
        self.state = state
        self.config = config
    }

    // MARK: - 对外入口

    /// App 激活时调用（自动同步开关控制）。
    public func onAppActivated() {
        guard settings.autoSyncOnActive else { return }
        startSync(fullSync: false)
    }

    /// 手动同步。返回是否成功。
    @discardableResult
    public func syncNow() -> Bool {
        startSync(fullSync: false)
        // 结果通过 state.syncPhase 反映，这里同步返回会立即 false；
        // SettingsView 在 Task 里 await 后用 state 判断。改为返回任务。
        return true
    }

    /// 手动同步（可等待结果）。
    /// 规则：
    /// - 若当前有「手动」同步进行中 → 返回 `.alreadySyncing`（UI 提示"正在同步中"）；
    /// - 若当前有「自动/后台」同步进行中 → 先取消它，再启动本次手动同步（手动优先）；
    /// - 否则直接启动手动同步。
    public func syncNowWithResult() async -> SyncResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSyncing {
                if isManualTask {
                    // 已有手动同步在进行，提示"正在同步中"而非失败。
                    lock.unlock()
                    continuation.resume(returning: .alreadySyncing)
                    return
                }
                // 自动/后台任务在进行：取消它，让本次手动同步接管。
                activeTask?.cancel()
                activeTask = nil
                isSyncing = false
                isManualTask = false
            }
            isSyncing = true
            isManualTask = true
            taskToken &+= 1
            let token = taskToken
            lock.unlock()

            state.resetProgress()
            state.syncPhase = .checkingAuth
            state.lastError = nil
            syncStage = "授权"
            activeTask = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(returning: .failed("内部错误"))
                    return
                }
                await self.performSync(fullSync: false, isManual: true, token: token)
                let result: SyncResult
                switch self.state.syncPhase {
                case .success:
                    result = .success
                case .failed(let msg):
                    result = .failed(msg)
                default:
                    result = .failed(self.state.lastError ?? "未知错误")
                }
                continuation.resume(returning: result)
            }
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

    /// 读取 HealthKit 真实授权状态并刷新 UI。
    /// 启动 / 设置页出现时调用，避免已授权仍显示"请求健康数据权限"。
    /// 只要 `statusMap` 中任一类型为已授权即视为已授权（不依赖 enabledTypes，
    /// 避免用户勾选集与授权集不重合时误判为未授权）。
    public func refreshHealthAuthStatus() async {
        // 先按系统 API 判断（写入类型会返回明确状态）。
        let statusMap = await healthService.authStatus(for: HealthDataType.allCases)
        if statusMap.values.contains(where: { $0 == .authorized }) {
            state.isHealthAuthorized = true
            return
        }
        // 关键：iOS 出于隐私，对「只读」类型的 authorizationStatus 永远返回
        // .sharingDenied / .notDetermined，不会透露用户是否真的授权读取。
        // 因此改用「实际读一次」探测：能顺利执行查询即视为已授权（数据可以为空）。
        let probe: Set<HealthDataType> = [.stepCount]
        do {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
            _ = try await healthService.fetchAll(types: probe, startDate: start, endDate: end)
            // 查询未抛错 —— 授权是通的
            state.isHealthAuthorized = true
        } catch {
            state.isHealthAuthorized = false
        }
    }

    /// 读取用户生物学性别（特征类型，本地读取，不弹窗）。
    public func loadBiologicalSex() async -> HKBiologicalSex {
        await healthService.readBiologicalSex()
    }

    /// 强制全量同步（重置游标）。
    public func forceFullSync() {
        cursorStore.reset()
        startSync(fullSync: true)
    }

    /// 请求健康权限（设置页用）。已授权则直接标记。
    /// 点击按钮时先检查真实状态：已授权直接置 true，不再重复弹系统授权框。
    public func requestAuthIfNeeded() async {
        let statusMap = await healthService.authStatus(for: HealthDataType.allCases)
        if statusMap.values.contains(where: { $0 == .authorized }) {
            state.isHealthAuthorized = true
            return
        }
        let ok = await ensureAuthorization()
        if ok {
            state.isHealthAuthorized = true
        } else {
            // 失败也以真实状态为准。
            await refreshHealthAuthStatus()
        }
    }

    /// 取消当前同步。
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isSyncing = false
        isManualTask = false
        state.syncPhase = .idle
    }

    public var isCurrentlySyncing: Bool { isSyncing }

    /// 当前失败阶段描述（仅用于日志诊断）。
    private var syncPhaseLabel: String { syncStage }

    // MARK: - 内部

    private func startSync(fullSync: Bool) {
        lock.lock()
        if isSyncing {
            lock.unlock()
            return
        }
        isSyncing = true
        isManualTask = false
        taskToken &+= 1
        let token = taskToken
        lock.unlock()

        state.resetProgress()
        state.syncPhase = .checkingAuth
        state.lastError = nil
        syncStage = "授权"

        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.performSync(fullSync: fullSync, isManual: false, token: token)
        }
    }

    private func performSync(fullSync: Bool, isManual: Bool, token: UInt64) async {
        // 1. 权限检查：先读取真实授权状态，未确定时再发起系统授权请求。
        await refreshHealthAuthStatus()
        guard await ensureAuthorization() else {
            finishSync(.failed("健康数据权限未授权，请在设置页授予读取权限"), token: token)
            return
        }

        // 2. 配置校验
        guard !settings.serverHost.isEmpty, !settings.apiToken.isEmpty else {
            finishSync(.failed("请先在设置页配置服务器地址与 Token"), token: token)
            return
        }

        // 2.5 探测服务器可达性（可选自愈已移除，直接同步；失败由重试兜底）

        let enabled = settings.enabledTypes
        guard !enabled.isEmpty else {
            finishSync(.failed("未启用任何数据类型"), token: token)
            return
        }

        // 3. 计算查询区间（游标策略）
        var cursor = cursorStore.load()
        let now = Date()

        let startDate: Date
        switch settings.syncMode {
        case .alwaysFull:
            startDate = settings.lookback.startDate(now: now)
        case .fullThenIncremental, .incremental:
            if fullSync || cursor.lastSyncedAt == nil {
                startDate = settings.lookback.startDate(now: now)
            } else {
                startDate = cursor.lastSyncedAt!
            }
        }

        // 4. 查询（后台 Task 不阻塞 UI）
        state.syncPhase = .syncing
        state.progress = 0
        syncStage = "查询"

        do {
            Logger.info("开始同步：\(enabled.count) 类型，起点 \(startDate)")
            let dtos = try await healthService.fetchAll(
                types: enabled,
                startDate: startDate,
                endDate: now
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.state.progress = fraction * 0.8
                }
            }
            Logger.info("HealthKit 查询完成：\(dtos.count) 条")

            // 5. 分片上传
            syncStage = "上传"
            let buffer = SyncBatchBuffer(batchSize: config.uploadBatchSize)
            let batches = buffer.split(dtos)
            state.totalSamples = dtos.count

            guard !batches.isEmpty else {
                // 无新数据也标记成功（更新游标）
                cursor.lastSyncedAt = now
                cursorStore.save(cursor)
                finishSync(.success, token: token)
                return
            }

            let device = SyncPayload.Device(model: deviceModel(), os: UIDevice.current.systemVersion, app: "HealthSync/1.0")
            var uploaded = 0

            for batch in batches {
                if Task.isCancelled {
                    finishSync(.failed("同步已取消"), token: token)
                    return
                }
                let payload = SyncPayload(
                    device: device,
                    batch: batch,
                    range: SyncPayload.Range(start: startDate, end: now),
                    cursorFingerprint: cursor.dedupFingerprint,
                    fullSync: (settings.syncMode == .alwaysFull || fullSync)
                )
                try await networkService.upload(payload: payload,
                                                host: settings.serverHost,
                                                port: settings.serverPort,
                                                token: settings.apiToken)
                uploaded += 1
                state.uploadedBatches = uploaded
                state.progress = 0.8 + 0.2 * (Double(uploaded) / Double(batches.count))
            }

            // 6. 更新游标
            cursor.lastSyncedAt = now
            cursor.dedupFingerprint = "\(now.timeIntervalSince1970)"
            cursorStore.save(cursor)

            finishSync(.success, token: token)
        } catch is CancellationError {
            Logger.error("同步被取消（isManual=\(isManual)）")
            finishSync(.failed("同步已取消"), token: token)
        } catch {
            let phaseLabel = syncPhaseLabel
            Logger.error("同步失败（阶段：\(phaseLabel)）：\(error.localizedDescription)（isManual=\(isManual)，启用类型 \(enabled.count) 种，起点 \(startDate)）")
            finishSync(.failed(error.localizedDescription), token: token)
        }
    }

    @MainActor
    private func ensureAuthorization() async -> Bool {
        // 先读取真实授权状态：已授权直接返回 true。
        await refreshHealthAuthStatus()
        if state.isHealthAuthorized {
            return true
        }

        // 未确定（首启）才发起系统授权请求；已拒绝则不再重复请求。
        let readTypes = settings.readTypes()
        guard !readTypes.isEmpty else { return false }
        do {
            try await healthService.requestReadAuthorization(for: settings.enabledTypes)
            // 请求后以真实状态为准刷新。
            await refreshHealthAuthStatus()
            return state.isHealthAuthorized
        } catch {
            state.isHealthAuthorized = false
            return false
        }
    }

    private func finishSync(_ phase: SyncPhase, token: UInt64? = nil) {
        // 若传入令牌且与当前活动任务不符（旧任务被取消后的收尾），则不触碰新任务的锁。
        if let token {
            if taskToken != token {
                // 旧任务收尾：仅更新 UI 状态，不清新任务的 isSyncing。
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
                return
            }
        }
        isSyncing = false
        isManualTask = false
        syncStage = "idle"
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
