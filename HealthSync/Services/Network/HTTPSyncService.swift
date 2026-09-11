import Foundation

/// 网络同步错误。
public enum SyncNetworkError: Error, LocalizedError {
    case invalidURL
    case badStatus(Int)
    case transport(Error)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的服务地址"
        case .badStatus(let code): return "服务器返回错误状态：\(code)"
        case .transport(let err): return "网络错误：\(err.localizedDescription)"
        case .emptyResponse: return "服务器返回空响应"
        }
    }
}

/// URLSession 封装的 Hermes 同步客户端：POST、Bearer Token、重试、超时、测试连接。
public struct HTTPSyncService: Sendable {
    private let config: SyncConfig
    private let keychain: KeychainStore

    public init(config: SyncConfig = .default,
                keychain: KeychainStore = KeychainStore()) {
        self.config = config
        self.keychain = keychain
    }

    /// 组装完整的 /api/ingest 地址。
    public static func ingestURL(host: String, port: String) -> URL? {
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = (Int(port) == 443) ? "https" : "http"
        components.host = host
        components.port = Int(port)
        components.path = "/api/ingest"
        return components.url
    }

    /// 发送健康样本批次。
    /// - Parameters:
    ///   - payload: SyncPayload
    ///   - host: 服务器地址（IP）
    ///   - port: 端口
    ///   - token: Bearer token
    ///   - retries: 重试次数
    public func upload(payload: SyncPayload,
                       host: String,
                       port: String,
                       token: String,
                       retries: Int? = nil) async throws {
        guard let url = Self.ingestURL(host: host, port: port) else {
            throw SyncNetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = config.requestTimeout

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let maxRetries = retries ?? config.maxRetryCount
        var attempt = 0
        var lastError: Error?

        while attempt <= maxRetries {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncNetworkError.emptyResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw SyncNetworkError.badStatus(http.statusCode)
                }
                return
            } catch let error as SyncNetworkError {
                throw error
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = config.retryBackoffBase * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                attempt += 1
            }
        }

        throw SyncNetworkError.transport(lastError ?? URLError(.cannotConnectToHost))
    }

    /// 测试连接：发送一个空批次，返回耗时。
    public func testConnection(host: String,
                               port: String,
                               token: String) async throws -> TimeInterval {
        let payload = SyncPayload(
            device: SyncPayload.Device(model: "", os: "", app: "HealthSync/ping"),
            batch: [],
            range: SyncPayload.Range(start: Date(), end: Date()),
            cursorFingerprint: nil,
            fullSync: false
        )
        let start = Date()
        try await upload(payload: payload, host: host, port: port, token: token, retries: 0)
        return Date().timeIntervalSince(start)
    }

    // MARK: - 敏感信息存取（Keychain）

    public func token() -> String? { keychain.read(.apiToken) }
    public func saveToken(_ token: String) { try? keychain.save(token, for: .apiToken) }
    public func host() -> String? { keychain.read(.serverHost) }
    public func saveHost(_ host: String) { try? keychain.save(host, for: .serverHost) }
    public func port() -> String? { keychain.read(.serverPort) }
    public func savePort(_ port: String) { try? keychain.save(port, for: .serverPort) }
}
