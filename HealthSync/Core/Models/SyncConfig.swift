import Foundation

/// 同步配置（并发度/批次/超时/重试）。
public struct SyncConfig: Codable, Sendable, Equatable {
    /// 单批样本数量上限（分批翻页）。
    public var batchSize: Int
    /// 每批样本上传条数上限（POST body 批次）。
    public var uploadBatchSize: Int
    /// 网络请求超时（秒）。
    public var requestTimeout: TimeInterval
    /// 失败最大重试次数。
    public var maxRetryCount: Int
    /// 指数退避基数（秒）。
    public var retryBackoffBase: TimeInterval
    /// 增量同步时向过去重叠查询的时间（秒），用于捕获延迟写入的历史数据。
    public var incrementalOverlap: TimeInterval
    /// 后台短任务向过去重叠查询的时间（秒）。比前台窗口短，避免刷新任务超时。
    public var backgroundIncrementalOverlap: TimeInterval

    public static let `default` = SyncConfig(
        batchSize: 2000,
        uploadBatchSize: 2000,
        requestTimeout: 30,
        maxRetryCount: 3,
        retryBackoffBase: 2.0,
        incrementalOverlap: 7 * 24 * 60 * 60,
        backgroundIncrementalOverlap: 24 * 60 * 60
    )

    public init(batchSize: Int = 2000,
                uploadBatchSize: Int = 2000,
                requestTimeout: TimeInterval = 30,
                maxRetryCount: Int = 3,
                retryBackoffBase: TimeInterval = 2.0,
                incrementalOverlap: TimeInterval = 7 * 24 * 60 * 60,
                backgroundIncrementalOverlap: TimeInterval = 24 * 60 * 60) {
        self.batchSize = batchSize
        self.uploadBatchSize = uploadBatchSize
        self.requestTimeout = requestTimeout
        self.maxRetryCount = maxRetryCount
        self.retryBackoffBase = retryBackoffBase
        self.incrementalOverlap = incrementalOverlap
        self.backgroundIncrementalOverlap = backgroundIncrementalOverlap
    }
}

/// 同步查询窗口策略，独立于 HealthKit，便于验证全量与增量边界。
public enum SyncWindowPolicy {
    public static func startDate(requestsAllHistory: Bool,
                                 lastSyncedAt: Date?,
                                 lookback: LookbackRange,
                                 overlap: TimeInterval,
                                 now: Date = Date()) -> Date {
        if requestsAllHistory {
            return .distantPast
        }
        if let lastSyncedAt {
            return lastSyncedAt.addingTimeInterval(-max(0, overlap))
        }
        return lookback.startDate(now: now)
    }
}
