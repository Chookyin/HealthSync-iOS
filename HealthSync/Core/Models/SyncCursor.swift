import Foundation

/// 同步游标：记录最后一次成功同步的时间与去重指纹。
/// 游标只做内存与 UserDefaults 中转，健康样本本身不做本地落盘。
public struct SyncCursor: Codable, Sendable, Equatable {
    /// 最后成功同步时间（增量查询起点）。
    public var lastSyncedAt: Date?
    /// 最后一次完整成功同步的完成时间，用于 UI 恢复。
    public var lastSuccessfulAt: Date?
    /// 首次全量同步完成时间。可区分「增量成功」与「完整历史已成功」。
    public var completedFullSyncAt: Date?
    /// 去重指纹（type + source 稳定哈希），防止重复上传。
    public var dedupFingerprint: String?

    public init(lastSyncedAt: Date? = nil,
                lastSuccessfulAt: Date? = nil,
                completedFullSyncAt: Date? = nil,
                dedupFingerprint: String? = nil) {
        self.lastSyncedAt = lastSyncedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.completedFullSyncAt = completedFullSyncAt
        self.dedupFingerprint = dedupFingerprint
    }

    public static let empty = SyncCursor()

    /// 重置游标（用于强制全量）。
    public mutating func reset() {
        lastSyncedAt = nil
        lastSuccessfulAt = nil
        completedFullSyncAt = nil
        dedupFingerprint = nil
    }
}

/// 同步游标持久化。
public final class SyncCursorStore: @unchecked Sendable {
    private static let key = "sync_cursor_v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SyncCursor {
        guard let data = defaults.data(forKey: Self.key),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: data) else {
            return .empty
        }
        return cursor
    }

    public func save(_ cursor: SyncCursor) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
