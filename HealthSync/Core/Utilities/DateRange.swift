import Foundation

/// 历史回溯范围选项。
public enum LookbackRange: Int, CaseIterable, Codable, Sendable, Identifiable {
    case last7Days = 7
    case last30Days = 30
    case lastYear = 365
    case all = 0

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        case .lastYear: return "近 1 年"
        case .all: return "全部"
        }
    }

    /// 与"当前时间"对应的起始日期。
    public func startDate(now: Date = Date()) -> Date {
        guard rawValue > 0 else { return Date.distantPast }
        return Calendar.current.date(byAdding: .day, value: -rawValue, to: now) ?? .distantPast
    }
}

public enum DateRange {
    /// 由起止时间构造 HK 查询区间。
    public static func make(start: Date, end: Date) -> (start: Date, end: Date) {
        let endDate = end <= start ? Date() : end
        return (start, endDate)
    }
}
