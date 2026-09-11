import Foundation
import Observation
import HealthKit

/// 同步阶段。
public enum SyncPhase: Sendable, Equatable {
    case idle
    case checkingAuth
    case syncing
    case success
    case failed(String)
}

/// 全局可观察状态。单一共享实例（`shared`），UI 与同步逻辑读同一份，
/// 避免「环境注入的实例」与「SyncCoordinator 内部实例」不同步导致授权状态/进度不刷新。
@Observable
public final class AppState {
    /// 全局唯一状态实例（UI 环境注入与 SyncCoordinator 共用）。
    public static let shared = AppState()

    public var syncPhase: SyncPhase = .idle
    public var progress: Double = 0
    public var currentType: String = ""
    public var lastSyncAt: Date?
    public var lastError: String?
    public var totalSamples: Int = 0
    public var uploadedBatches: Int = 0
    public var isHealthAuthorized: Bool = false
    /// 用户生物学性别（来自 HealthKit 特征，用于按性别过滤数据类型）。
    public var biologicalSex: HKBiologicalSex = .notSet

    public init() {}

    public func resetProgress() {
        progress = 0
        currentType = ""
        uploadedBatches = 0
        totalSamples = 0
    }
}
