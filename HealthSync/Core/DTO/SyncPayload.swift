import Foundation

/// POST body（批次/设备信息/时间范围/指纹）。
public struct SyncPayload: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public var model: String
        public var os: String
        public var app: String
    }

    public struct Range: Codable, Sendable {
        public var start: Date
        public var end: Date
    }

    public var device: Device
    public var batch: [HealthSampleDTO]
    public var range: Range
    public var cursorFingerprint: String?
    public var fullSync: Bool

    public init(device: Device,
                batch: [HealthSampleDTO],
                range: Range,
                cursorFingerprint: String?,
                fullSync: Bool) {
        self.device = device
        self.batch = batch
        self.range = range
        self.cursorFingerprint = cursorFingerprint
        self.fullSync = fullSync
    }
}
