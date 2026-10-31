import XCTest
import HealthKit
@testable import HealthSync

final class HealthSyncCoreTests: XCTestCase {
    func testServerAddressAcceptsHostAndFullURL() throws {
        let hostOnly = try XCTUnwrap(
            ServerAddress(host: "example.com", port: "8443", defaultScheme: "https")
        )
        XCTAssertEqual(hostOnly.scheme, "https")
        XCTAssertEqual(hostOnly.host, "example.com")
        XCTAssertEqual(hostOnly.port, 8443)

        let fullURL = try XCTUnwrap(
            ServerAddress(host: "http://192.168.1.8:8765", port: "443")
        )
        XCTAssertEqual(
            fullURL.url(path: "/api/ingest")?.absoluteString,
            "http://192.168.1.8:8765/api/ingest"
        )
    }

    func testServerAddressRejectsInvalidInput() {
        XCTAssertNil(ServerAddress(host: "example.com", port: "70000"))
        XCTAssertNil(ServerAddress(host: "https://example.com/path", port: "443"))
    }

    func testSyncWindowPolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSync = now.addingTimeInterval(-86_400)

        XCTAssertEqual(
            SyncWindowPolicy.startDate(
                requestsAllHistory: true,
                lastSyncedAt: lastSync,
                lookback: .last7Days,
                overlap: 3 * 86_400,
                now: now
            ),
            .distantPast
        )
        XCTAssertEqual(
            SyncWindowPolicy.startDate(
                requestsAllHistory: false,
                lastSyncedAt: lastSync,
                lookback: .last7Days,
                overlap: 3 * 86_400,
                now: now
            ),
            lastSync.addingTimeInterval(-3 * 86_400)
        )
    }

    func testFingerprintIsStableSHA256() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = HealthSampleMapper.fingerprint(
            id: id,
            type: "stepCount",
            start: date,
            end: date,
            source: "com.apple.Health"
        )
        let second = HealthSampleMapper.fingerprint(
            id: id,
            type: "stepCount",
            start: date,
            end: date,
            source: "com.apple.Health"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
    }

    func testLegacyCursorDecodes() throws {
        struct LegacyCursor: Encodable {
            var lastSyncedAt: Date?
            var dedupFingerprint: String?
        }

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONEncoder().encode(
            LegacyCursor(lastSyncedAt: date, dedupFingerprint: "legacy")
        )
        let cursor = try JSONDecoder().decode(SyncCursor.self, from: data)
        XCTAssertEqual(cursor.lastSyncedAt, date)
        XCTAssertNil(cursor.lastSuccessfulAt)
        XCTAssertNil(cursor.completedFullSyncAt)
    }

    func testBackgroundSyncPolicyRequiresFullHistoryOnlyWhenConfigured() {
        XCTAssertTrue(
            BackgroundSyncPolicy.needsInitialFullSync(
                cursor: .empty,
                mode: .fullThenIncremental
            )
        )
        XCTAssertFalse(
            BackgroundSyncPolicy.needsInitialFullSync(
                cursor: .empty,
                mode: .incremental
            )
        )
        XCTAssertFalse(
            BackgroundSyncPolicy.needsInitialFullSync(
                cursor: SyncCursor(completedFullSyncAt: Date()),
                mode: .fullThenIncremental
            )
        )
    }

    func testBackgroundDeliveryReconfiguresWhenSleepStageChanges() {
        XCTAssertTrue(
            BackgroundDeliveryPolicy.needsReconfiguration(
                targetIdentifiers: ["HKCategoryTypeIdentifierSleepAnalysis"],
                observedIdentifiers: ["HKCategoryTypeIdentifierSleepAnalysis"],
                targetTypes: [.sleepREM],
                observedTypes: [.sleepDeep]
            )
        )
        XCTAssertFalse(
            BackgroundDeliveryPolicy.needsReconfiguration(
                targetIdentifiers: ["HKCategoryTypeIdentifierSleepAnalysis"],
                observedIdentifiers: ["HKCategoryTypeIdentifierSleepAnalysis"],
                targetTypes: [.sleepREM],
                observedTypes: [.sleepREM]
            )
        )
    }

    func testUploadRetriesRetryableServerStatus() async throws {
        let transport = StubUploadTransport(responses: [
            UploadHTTPResponse(statusCode: 503, retryAfter: "0"),
            UploadHTTPResponse(statusCode: 200, retryAfter: nil)
        ])
        let service = HTTPSyncService(
            config: SyncConfig(maxRetryCount: 1, retryBackoffBase: 0),
            keychain: KeychainStore(),
            uploadTransport: transport
        )
        let address = try XCTUnwrap(
            ServerAddress(host: "example.com", port: "443", defaultScheme: "https")
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = SyncPayload(
            device: .init(model: "iPhone", os: "18.0", app: "HealthSync/test"),
            batch: [],
            range: .init(start: now, end: now),
            cursorFingerprint: nil,
            fullSync: false
        )

        try await service.upload(
            payload: payload,
            address: address,
            token: "test-token",
            retries: 1
        )

        let requestSnapshot = await transport.snapshot()
        XCTAssertEqual(requestSnapshot.attemptCount, 2)
        XCTAssertEqual(requestSnapshot.request?.url?.path, "/api/ingest")
        XCTAssertEqual(
            requestSnapshot.request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )
    }

    func testUploadDoesNotRetryUnauthorizedStatus() async throws {
        let transport = StubUploadTransport(responses: [
            UploadHTTPResponse(statusCode: 401, retryAfter: nil),
            UploadHTTPResponse(statusCode: 200, retryAfter: nil)
        ])
        let service = HTTPSyncService(
            config: SyncConfig(maxRetryCount: 3, retryBackoffBase: 0),
            keychain: KeychainStore(),
            uploadTransport: transport
        )
        let address = try XCTUnwrap(
            ServerAddress(host: "example.com", port: "443", defaultScheme: "https")
        )
        let payload = makeUploadPayload()

        do {
            try await service.upload(
                payload: payload,
                address: address,
                token: "bad-token",
                retries: 3
            )
            XCTFail("401 should not be accepted")
        } catch SyncNetworkError.badStatus(let code) {
            XCTAssertEqual(code, 401)
        }

        let requestSnapshot = await transport.snapshot()
        XCTAssertEqual(requestSnapshot.attemptCount, 1)
    }

    func testUploadCancellationPropagates() async throws {
        let transport = BlockingUploadTransport()
        let service = HTTPSyncService(
            config: SyncConfig(maxRetryCount: 3, retryBackoffBase: 0),
            keychain: KeychainStore(),
            uploadTransport: transport
        )
        let address = try XCTUnwrap(
            ServerAddress(host: "example.com", port: "443", defaultScheme: "https")
        )
        let payload = makeUploadPayload()

        let task = Task {
            try await service.upload(
                payload: payload,
                address: address,
                token: "test-token",
                retries: 3
            )
        }
        await transport.waitUntilStarted()
        task.cancel()

        do {
            try await task.value
            XCTFail("Cancelled upload should not succeed")
        } catch is CancellationError {
            let count = await transport.attemptCount()
            XCTAssertEqual(count, 1)
        }
    }

    func testHealthSampleCategoryMapping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let heartSample = HKQuantitySample(
            type: heartType,
            quantity: HKQuantity(
                unit: HKUnit.count().unitDivided(by: .minute()),
                doubleValue: 72
            ),
            start: now,
            end: now
        )
        XCTAssertEqual(HealthSampleMapper.map(heartSample).category, "heart")

        let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        let sleepSample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: now,
            end: now.addingTimeInterval(3_600)
        )
        let sleepDTO = HealthSampleMapper.map(sleepSample)
        XCTAssertEqual(sleepDTO.category, "sleep")
        XCTAssertEqual(sleepDTO.valueDescription, "asleepDeep")
    }

    func testBatchBufferHonorsSize() {
        let samples = (0..<5).map { index in
            HealthSampleDTO(
                id: String(index),
                type: "test",
                category: "test",
                startDate: Date(timeIntervalSince1970: Double(index)),
                endDate: Date(timeIntervalSince1970: Double(index)),
                fingerprint: String(index)
            )
        }
        let batches = SyncBatchBuffer(batchSize: 2).split(samples)
        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
    }

    private func makeUploadPayload() -> SyncPayload {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return SyncPayload(
            device: .init(model: "iPhone", os: "18.0", app: "HealthSync/test"),
            batch: [],
            range: .init(start: now, end: now),
            cursorFingerprint: nil,
            fullSync: false
        )
    }
}

private actor StubUploadTransport: UploadTransport {
    private var responses: [UploadHTTPResponse]
    private var attemptCount = 0
    private var lastRequest: URLRequest?

    init(responses: [UploadHTTPResponse]) {
        self.responses = responses
    }

    func upload(data: Data, request: URLRequest) async throws -> UploadHTTPResponse {
        attemptCount += 1
        lastRequest = request
        guard !responses.isEmpty else {
            throw BackgroundUploadError.missingResponse
        }
        return responses.removeFirst()
    }

    func snapshot() -> (attemptCount: Int, request: URLRequest?) {
        (attemptCount, lastRequest)
    }
}

private actor BlockingUploadTransport: UploadTransport {
    private var started = false
    private var attempts = 0

    func upload(data: Data, request: URLRequest) async throws -> UploadHTTPResponse {
        attempts += 1
        started = true
        try await Task.sleep(for: .seconds(30))
        return UploadHTTPResponse(statusCode: 200, retryAfter: nil)
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func attemptCount() -> Int {
        attempts
    }
}
