import Foundation

/// 批次缓冲与节流：把大量 DTO 分片为上传批次，便于进度反馈与压缩。
public struct SyncBatchBuffer: Sendable {
    public let batchSize: Int

    public init(batchSize: Int) {
        self.batchSize = batchSize
    }

    /// 将 DTO 数组切分为多个批次。
    public func split(_ dtos: [HealthSampleDTO]) -> [[HealthSampleDTO]] {
        guard batchSize > 0 else { return dtos.isEmpty ? [] : [dtos] }
        var result: [[HealthSampleDTO]] = []
        var current: [HealthSampleDTO] = []
        current.reserveCapacity(batchSize)
        for dto in dtos {
            current.append(dto)
            if current.count == batchSize {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
