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
}
