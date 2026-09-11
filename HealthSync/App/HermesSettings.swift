import Foundation
import HealthKit
import Observation

/// 同步模式：增量 / 首次全量后增量 / 每次强制全量。
public enum SyncMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case incremental = "incremental"
    case fullThenIncremental = "fullThenIncremental"
    case alwaysFull = "alwaysFull"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .incremental: return "仅新增（增量）"
        case .fullThenIncremental: return "首次全量后增量"
        case .alwaysFull: return "每次强制全量"
        }
    }
}

/// 设置模型：服务器/Token/数据范围/主题/开关。
@Observable
public final class HermesSettings {
    // 服务器（Token 存 Keychain，其余存 UserDefaults）
    public var serverHost: String = ""
    public var serverPort: String = "443"
    public var apiToken: String = "" {
        didSet { saveToken() }
    }

    // 数据范围
    public var syncMode: SyncMode = .incremental
    public var lookback: LookbackRange = .last7Days
    public var enabledTypes: Set<HealthDataType> = HealthDataType.defaultEnabled
    public var autoSyncOnActive: Bool = true
    public var backgroundRetry: Bool = true

    // 主题
    public var colorScheme: AppColorScheme = .system

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    /// UserDefaults 键：标记是否已完成「数据类型默认全量」的初始化。
    private static let fullEnabledTypesKey = "didInitFullEnabledTypes"

    public init(defaults: UserDefaults = .standard,
                keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        load()
    }

    private func load() {
        if let host = keychain.read(.serverHost), !host.isEmpty {
            serverHost = host
        } else if let stored = defaults.string(forKey: "serverHost"), !stored.isEmpty {
            serverHost = stored
        }
        if let port = keychain.read(.serverPort), !port.isEmpty {
            serverPort = port
        } else if let stored = defaults.string(forKey: "serverPort"), !stored.isEmpty {
            serverPort = stored
        }
        // 端口迁移：旧版存的是服务器直连端口 8765；隧道模式统一走 443。
        if serverPort == "8765" {
            serverPort = "443"
            defaults.set(serverPort, forKey: "serverPort")
            try? keychain.save(serverPort, for: .serverPort)
        }
        if let token = keychain.read(.apiToken) {
            apiToken = token
        } else if let stored = defaults.string(forKey: "apiToken"), !stored.isEmpty {
            apiToken = stored
        }

        if let raw = defaults.string(forKey: "syncMode"),
           let mode = SyncMode(rawValue: raw) {
            syncMode = mode
        }
        if let raw = defaults.object(forKey: "lookback") as? Int,
           let lb = LookbackRange(rawValue: raw) {
            lookback = lb
        }
        if let data = defaults.data(forKey: "enabledTypes"),
           let set = try? JSONDecoder().decode(Set<HealthDataType>.self, from: data) {
            enabledTypes = set
        }
        autoSyncOnActive = defaults.object(forKey: "autoSyncOnActive") as? Bool ?? true
        backgroundRetry = defaults.object(forKey: "backgroundRetry") as? Bool ?? true
        if let raw = defaults.string(forKey: "colorScheme"),
           let cs = AppColorScheme(rawValue: raw) {
            colorScheme = cs
        }

        // 首次安装（或升级）数据范围兜底：仅当从未持久化过 enabledTypes 时，
        // 才用全量默认初始化；一旦用户改过（存在已存键），绝不覆盖用户的修改。
        if !defaults.bool(forKey: Self.fullEnabledTypesKey) {
            if defaults.data(forKey: "enabledTypes") == nil {
                enabledTypes = HealthDataType.defaultEnabled
                defaults.set(true, forKey: Self.fullEnabledTypesKey)
                persist()
            } else {
                // 已有持久化用户选择：仅补打标记，不再覆盖。
                defaults.set(true, forKey: Self.fullEnabledTypesKey)
            }
        }
    }

    public func persist() {
        defaults.set(serverHost, forKey: "serverHost")
        defaults.set(serverPort, forKey: "serverPort")
        defaults.set(syncMode.rawValue, forKey: "syncMode")
        defaults.set(lookback.rawValue, forKey: "lookback")
        if let data = try? JSONEncoder().encode(enabledTypes) {
            defaults.set(data, forKey: "enabledTypes")
        }
        defaults.set(autoSyncOnActive, forKey: "autoSyncOnActive")
        defaults.set(backgroundRetry, forKey: "backgroundRetry")
        defaults.set(colorScheme.rawValue, forKey: "colorScheme")
        saveToken()
        try? keychain.save(serverHost, for: .serverHost)
        try? keychain.save(serverPort, for: .serverPort)
    }

    private func saveToken() {
        try? keychain.save(apiToken, for: .apiToken)
    }

    /// 判断是否为私有/回环地址（192.168.x、10.x、172.16-31.x、127.x、localhost）。
    /// 这类地址只能在同一局域网内访问，用于迁移旧配置。
    private static func isPrivateAddress(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h == "localhost" || h.hasPrefix("127.") { return true }
        if h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("10.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// 判断是否为裸 IPv4 地址（4 段点分十进制），无论私有还是公网。
    /// 用于迁移：任一裸 IP 都触发重置为 HTTPS 隧道域名（避免 ATS 对公网 HTTP IP 的拦截）。
    private static func isPlainIP(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        let parts = h.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let v = Int(part), (0...255).contains(v) else { return false }
            return true
        }
    }

    /// 当前启用的只读授权类型（过滤掉无法映射为 HKObjectType 的类型）。
    public func readTypes() -> Set<HKObjectType> {
        Set(enabledTypes.compactMap { $0.objectType })
    }
}

/// 主题方案。
public enum AppColorScheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}
