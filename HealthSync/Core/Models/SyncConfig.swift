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
    /// 并发查询的类型数上限。
    public var maxConcurrentQueries: Int

    public static let `default` = SyncConfig(
        batchSize: 2000,
        uploadBatchSize: 2000,
        requestTimeout: 30,
        maxRetryCount: 3,
        retryBackoffBase: 2.0,
        maxConcurrentQueries: 4
    )

    public init(batchSize: Int = 2000,
                uploadBatchSize: Int = 2000,
                requestTimeout: TimeInterval = 30,
                maxRetryCount: Int = 3,
                retryBackoffBase: TimeInterval = 2.0,
                maxConcurrentQueries: Int = 4) {
        self.batchSize = batchSize
        self.uploadBatchSize = uploadBatchSize
        self.requestTimeout = requestTimeout
        self.maxRetryCount = maxRetryCount
        self.retryBackoffBase = retryBackoffBase
        self.maxConcurrentQueries = maxConcurrentQueries
    }
}
