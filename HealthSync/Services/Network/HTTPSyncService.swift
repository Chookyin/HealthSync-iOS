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
        case .badStatus(let code):
            if code == 401 || code == 403 {
                return "鉴权失败：请检查 API Token"
            }
            return "服务器返回错误状态：\(code)"
        case .transport(let err): return "网络错误：\(err.localizedDescription)"
        case .emptyResponse: return "服务器返回空响应"
        }
    }
}

/// 经过校验的服务器连接信息。
/// 支持主机和端口分开填写，也支持粘贴完整 URL。
public struct ServerAddress: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(host input: String,
                 port inputPort: String,
                 defaultScheme: String = "https") {
        let trimmedHost = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = inputPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let port = Int(trimmedPort),
              (1...65_535).contains(port) else {
            return nil
        }

        if let components = URLComponents(string: trimmedHost),
           let parsedScheme = components.scheme,
           let parsedHost = components.host,
           !parsedHost.isEmpty {
            guard let scheme = Self.validatedScheme(parsedScheme),
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/" else {
                return nil
            }
            self.scheme = scheme
            self.host = parsedHost
            self.port = components.port ?? port
            guard url(path: "/") != nil else { return nil }
            return
        }

        let host = trimmedHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !host.contains("/") else { return nil }
        let scheme = Self.validatedScheme(defaultScheme)
            ?? (port == 443 ? "https" : "http")

        self.scheme = scheme
        self.host = host
        self.port = port
        guard url(path: "/") != nil else { return nil }
    }

    /// 生成固定 API 路径对应的 URL。
    public func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    private static func validatedScheme(_ value: String) -> String? {
        let scheme = value.lowercased()
        return ["http", "https"].contains(scheme) ? scheme : nil
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
    public static func ingestURL(host: String,
                                 port: String,
                                 scheme: String = "https") -> URL? {
        ServerAddress(host: host, port: port, defaultScheme: scheme)?
            .url(path: "/api/ingest")
    }

    /// 发送健康样本批次。
    /// - Parameters:
    ///   - payload: SyncPayload
    ///   - host: 服务器主机名、IP 或完整 URL
    ///   - port: 端口
    ///   - scheme: 未填写完整 URL 时使用的协议
    ///   - token: Bearer token
    ///   - retries: 重试次数
    public func upload(payload: SyncPayload,
                       host: String,
                       port: String,
                       scheme: String = "https",
                       token: String,
                       retries: Int? = nil) async throws {
        guard let address = ServerAddress(host: host,
                                          port: port,
                                          defaultScheme: scheme) else {
            throw SyncNetworkError.invalidURL
        }
        try await upload(payload: payload,
                         address: address,
                         token: token,
                         retries: retries)
    }

    /// 使用已校验的服务器连接发送健康样本批次。
    public func upload(payload: SyncPayload,
                       address: ServerAddress,
                       token: String,
                       retries: Int? = nil) async throws {
        guard let url = address.url(path: "/api/ingest") else {
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
        var lastError: Error = URLError(.cannotConnectToHost)

        while attempt <= maxRetries {
            try Task.checkCancellation()
            var retryAfter: TimeInterval?
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncNetworkError.emptyResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    retryAfter = Self.retryAfter(from: http)
                    throw SyncNetworkError.badStatus(http.statusCode)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SyncNetworkError {
                let shouldRetry: Bool
                switch error {
                case .emptyResponse:
                    shouldRetry = true
                case .badStatus(let statusCode):
                    shouldRetry = Self.isRetryable(statusCode: statusCode)
                case .invalidURL, .transport:
                    shouldRetry = false
                }
                guard shouldRetry, attempt < maxRetries else {
                    throw error
                }
                lastError = error
                let delay = retryAfter
                    ?? config.retryBackoffBase * pow(2.0, Double(attempt))
                try await Self.sleep(seconds: delay)
                attempt += 1
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < maxRetries else {
                    throw error
                }
                let delay = config.retryBackoffBase * pow(2.0, Double(attempt))
                try await Self.sleep(seconds: delay)
                attempt += 1
            }
        }

        throw lastError
    }

    /// 测试连接：通过真实鉴权接口发送空批次，返回耗时。
    public func testConnection(address: ServerAddress,
                               token: String) async throws -> TimeInterval {
        let payload = SyncPayload(
            device: SyncPayload.Device(model: "", os: "", app: "HealthSync/ping"),
            batch: [],
            range: SyncPayload.Range(start: Date(), end: Date()),
            cursorFingerprint: nil,
            fullSync: false
        )
        let start = Date()
        try await upload(payload: payload, address: address, token: token, retries: 0)
        return Date().timeIntervalSince(start)
    }

    /// 兼容旧调用：通过主机和端口测试真实鉴权接口。
    public func testConnection(host: String,
                               port: String,
                               scheme: String = "https",
                               token: String) async throws -> TimeInterval {
        guard let address = ServerAddress(host: host,
                                          port: port,
                                          defaultScheme: scheme) else {
            throw SyncNetworkError.invalidURL
        }
        return try await testConnection(address: address, token: token)
    }

    // MARK: - 敏感信息存取（Keychain）

    public func token() -> String? { keychain.read(.apiToken) }
    public func saveToken(_ token: String) { try? keychain.save(token, for: .apiToken) }
    public func host() -> String? { keychain.read(.serverHost) }
    public func saveHost(_ host: String) { try? keychain.save(host, for: .serverHost) }
    public func port() -> String? { keychain.read(.serverPort) }
    public func savePort(_ port: String) { try? keychain.save(port, for: .serverPort) }

    private static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        return nil
    }

    private static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(min(seconds, 3_600) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
