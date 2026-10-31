import Foundation

/// 后台 URLSession 返回的最小响应信息，避免把网络对象跨并发边界传递。
struct UploadHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let retryAfter: String?
}

/// 可替换的上传传输层，便于验证重试和服务端状态处理。
protocol UploadTransport: Sendable {
    func upload(data: Data, request: URLRequest) async throws -> UploadHTTPResponse
}

enum BackgroundUploadError: Error, LocalizedError {
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .missingResponse:
            return "后台上传没有收到服务器响应"
        }
    }
}

/// 使用 file-backed upload task，使请求在 App 挂起或被系统回收后仍能由系统继续传输。
final class BackgroundUploadSession: UploadTransport, @unchecked Sendable {
    static let shared = BackgroundUploadSession()

    private static let sessionIdentifier =
        "\(Bundle.main.bundleIdentifier ?? "com.example.HealthSync").background-upload"

    private let delegate: UploadSessionDelegate
    private let session: URLSession
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let delegate = UploadSessionDelegate(fileManager: fileManager)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 1

        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.fileManager = fileManager
    }

    func upload(data: Data, request: URLRequest) async throws -> UploadHTTPResponse {
        let fileURL = try makeUploadFile(data: data)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = fileURL.path

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(taskIdentifier: task.taskIdentifier,
                                  continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 后台会话唤回 App 后，由 UIApplicationDelegate 转交系统完成回调。
    func storeBackgroundEventsCompletion(_ completion: @escaping () -> Void) {
        delegate.storeBackgroundEventsCompletion(
            BackgroundEventsCompletion(completion)
        )
    }

    private func makeUploadFile(data: Data) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HealthSyncBackgroundUploads", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return fileURL
    }
}

private final class UploadSessionDelegate: NSObject,
                                          URLSessionTaskDelegate,
                                          @unchecked Sendable {
    fileprivate typealias PendingUpload = CheckedContinuation<UploadHTTPResponse, Error>

    private let lock = NSLock()
    private let fileManager: FileManager
    private var pending: [Int: PendingUpload] = [:]
    private var backgroundEventsCompletion: BackgroundEventsCompletion?

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    fileprivate func register(taskIdentifier: Int, continuation: PendingUpload) {
        lock.lock()
        pending[taskIdentifier] = continuation
        lock.unlock()
    }

    func storeBackgroundEventsCompletion(_ completion: BackgroundEventsCompletion) {
        lock.lock()
        let previous = backgroundEventsCompletion
        backgroundEventsCompletion = completion
        lock.unlock()
        previous?.call()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let continuation: PendingUpload?
        lock.lock()
        continuation = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        removeUploadFile(for: task)

        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: BackgroundUploadError.missingResponse)
            return
        }
        continuation.resume(
            returning: UploadHTTPResponse(
                statusCode: response.statusCode,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        completion?.call()
    }

    private func removeUploadFile(for task: URLSessionTask) {
        guard let path = task.taskDescription, !path.isEmpty else { return }
        try? fileManager.removeItem(atPath: path)
    }
}

private final class BackgroundEventsCompletion: @unchecked Sendable {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func call() {
        completion()
    }
}
