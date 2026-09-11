import Foundation
import HealthKit

/// 权限状态枚举。
public enum HealthAuthStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// HealthKit 服务协议（便于测试 mock）。
public protocol HealthStoreProtocol: Sendable {
    func requestAuthorization(toShare sharing: Set<HKSampleType>,
                              read reading: Set<HKObjectType>) async throws
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
}

/// 查询结果分页响应。
public struct HealthQueryResponse: Sendable {
    public var samples: [HKSample]
    public var hasMore: Bool
    public var returnedCount: Int

    public init(samples: [HKSample], hasMore: Bool) {
        self.samples = samples
        self.hasMore = hasMore
        self.returnedCount = samples.count
    }
}
