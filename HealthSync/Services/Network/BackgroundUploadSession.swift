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

private struct BackgroundUploadTaskRecord: Codable, Sendable {
    let taskIdentifier: Int
    let filePath: String
    let createdAt: Date
}

private final class BackgroundUploadTaskRecordStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent(
            "HealthSync",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent(
            "background-upload-tasks.json"
        )
    }

    func record(taskIdentifier: Int, filePath: String) {
        lock.lock()
        defer { lock.unlock() }

        var records = readUnlocked()
        records.removeAll { $0.taskIdentifier == taskIdentifier }
        records.append(
            BackgroundUploadTaskRecord(
                taskIdentifier: taskIdentifier,
                filePath: filePath,
                createdAt: Date()
            )
        )
        writeUnlocked(records)
    }

    func remove(taskIdentifier: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var records = readUnlocked()
        let filePath = records
            .first(where: { $0.taskIdentifier == taskIdentifier })?
            .filePath
        records.removeAll { $0.taskIdentifier == taskIdentifier }
        writeUnlocked(records)
        return filePath
    }

    func removeMissing(liveTaskIdentifiers: Set<Int>) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let records = readUnlocked()
        let missing = records.filter {
            !liveTaskIdentifiers.contains($0.taskIdentifier)
        }
        guard !missing.isEmpty else { return [] }

        let remaining = records.filter {
            liveTaskIdentifiers.contains($0.taskIdentifier)
        }
        writeUnlocked(remaining)
        return missing.map(\.filePath)
    }

    private func readUnlocked() -> [BackgroundUploadTaskRecord] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? JSONDecoder().decode(
            [BackgroundUploadTaskRecord].self,
            from: data
        )) ?? []
    }

    private func writeUnlocked(_ records: [BackgroundUploadTaskRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            try data.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        } catch {
            Logger.error("后台上传任务记录保存失败：\(error.localizedDescription)")
        }
    }
}

/// 使用 file-backed upload task，使请求在 App 挂起或被系统回收后仍能由系统继续传输。
final class BackgroundUploadSession: UploadTransport, @unchecked Sendable {
    static let shared = BackgroundUploadSession()

    static let sessionIdentifier =
        "\(Bundle.main.bundleIdentifier ?? "com.example.HealthSync").background-upload"

    private let delegate: UploadSessionDelegate
    private let session: URLSession
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let recordStore = BackgroundUploadTaskRecordStore(
            fileManager: fileManager
        )
        let delegate = UploadSessionDelegate(
            fileManager: fileManager,
            recordStore: recordStore
        )
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
        session.getAllTasks { tasks in
            delegate.reconcile(
                liveTaskIdentifiers: Set(tasks.map(\.taskIdentifier))
            )
        }
    }

    func upload(data: Data, request: URLRequest) async throws -> UploadHTTPResponse {
        let fileURL = try makeUploadFile(data: data)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = fileURL.path
        delegate.record(task: task)

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

    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) {
        delegate.setRecoveryHandler(handler)
    }

    private func makeUploadFile(data: Data) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var directory = baseURL
            .appendingPathComponent("HealthSyncBackgroundUploads", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
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
    private let recordStore: BackgroundUploadTaskRecordStore
    private var pending: [Int: PendingUpload] = [:]
    private var backgroundEventsCompletion: BackgroundEventsCompletion?
    private var recoveryHandler: (@Sendable () -> Void)?
    private var hadUnmatchedCompletion = false
    private var backgroundEventsDidFinish = false

    init(fileManager: FileManager,
         recordStore: BackgroundUploadTaskRecordStore) {
        self.fileManager = fileManager
        self.recordStore = recordStore
    }

    fileprivate func register(taskIdentifier: Int, continuation: PendingUpload) {
        lock.lock()
        pending[taskIdentifier] = continuation
        lock.unlock()
    }

    fileprivate func record(task: URLSessionTask) {
        guard let path = task.taskDescription, !path.isEmpty else { return }
        recordStore.record(
            taskIdentifier: task.taskIdentifier,
            filePath: path
        )
    }

    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        recoveryHandler = handler
        let shouldCall = hadUnmatchedCompletion
            && backgroundEventsDidFinish
        if shouldCall {
            hadUnmatchedCompletion = false
        }
        lock.unlock()

        if shouldCall {
            handler()
        }
    }

    func reconcile(liveTaskIdentifiers: Set<Int>) {
        let missingFiles = recordStore.removeMissing(
            liveTaskIdentifiers: liveTaskIdentifiers
        )
        guard !missingFiles.isEmpty else { return }

        for path in missingFiles {
            try? fileManager.removeItem(atPath: path)
        }

        lock.lock()
        let shouldCall = backgroundEventsDidFinish
        let handler = shouldCall ? recoveryHandler : nil
        if !shouldCall {
            hadUnmatchedCompletion = true
        }
        lock.unlock()

        if shouldCall {
            handler?()
        }
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

        let recordedPath = removeUploadFile(for: task)

        guard let continuation else {
            lock.lock()
            hadUnmatchedCompletion = true
            lock.unlock()
            if recordedPath != nil {
                Logger.debug("后台任务在进程恢复后完成，等待重新调度同步")
            }
            return
        }
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
        backgroundEventsDidFinish = true
        let handler = hadUnmatchedCompletion ? recoveryHandler : nil
        hadUnmatchedCompletion = false
        lock.unlock()
        handler?()
        completion?.call()
    }

    @discardableResult
    private func removeUploadFile(for task: URLSessionTask) -> String? {
        let recordedPath = recordStore.remove(
            taskIdentifier: task.taskIdentifier
        )
        let path = task.taskDescription ?? recordedPath
        guard let path, !path.isEmpty else { return nil }
        try? fileManager.removeItem(atPath: path)
        return path
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
