import Foundation

/// 统一健康样本 DTO（Codable，可序列化为 JSON 上传）。
public struct HealthSampleDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var type: String
    public var category: String
    public var startDate: Date
    public var endDate: Date
    public var value: Double?
    public var unit: String?
    /// 分类型样本的数值含义（如睡眠阶段 rawValue）。
    public var valueDescription: String?
    /// 来源设备名。
    public var sourceName: String?
    public var sourceBundleID: String?
    public var deviceName: String?
    /// 锻炼/ECG 等特殊样本附加信息。
    public var metadata: [String: String]?
    /// 去重指纹。
    public var fingerprint: String

    public init(id: String,
                type: String,
                category: String,
                startDate: Date,
                endDate: Date,
                value: Double? = nil,
                unit: String? = nil,
                valueDescription: String? = nil,
                sourceName: String? = nil,
                sourceBundleID: String? = nil,
                deviceName: String? = nil,
                metadata: [String: String]? = nil,
                fingerprint: String) {
        self.id = id
        self.type = type
        self.category = category
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.valueDescription = valueDescription
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.deviceName = deviceName
        self.metadata = metadata
        self.fingerprint = fingerprint
    }
}
