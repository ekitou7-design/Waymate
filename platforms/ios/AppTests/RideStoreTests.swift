import Foundation
import XCTest
@testable import Waymate

final class RideStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("Rides/history.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func record(_ seconds: Double = 0, movingTime: Double = 10) -> RideRecord {
        RideRecord(startedAt: Date(timeIntervalSince1970: seconds),
                   endedAt: Date(timeIntervalSince1970: seconds + 20), elapsedTime: 20,
                   movingTime: movingTime, distance: 50, maxSpeed: 7,
                   track: [point(0, segment: 0), point(2, segment: 0),
                           point(40, segment: 1), point(42, segment: 1)])
    }
    private func point(_ seconds: Double, segment: Int) -> RideTrackPoint {
        .init(latitude: 36 + seconds / 100_000, longitude: 117, timestamp: Date(timeIntervalSince1970: seconds),
              horizontalAccuracy: 3, speed: 5, segment: segment)
    }

    func testMissingFileLoadsEmptyWithoutCreatingFile() async throws {
        let store = RideStore(fileURL: file)
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAppendReloadMultipleRecordsNewestFirstAndDuplicateSave() async throws {
        let store = RideStore(fileURL: file)
        let old = record(10), new = record(100), middle = record(50)
        try await store.append(old)
        try await store.append(new)
        try await store.append(middle)
        let duplicate = try await store.append(new)
        XCTAssertEqual(duplicate, [new, middle, old])
        let reloaded = try await RideStore(fileURL: file).load()
        XCTAssertEqual(reloaded, duplicate)
        XCTAssertEqual(reloaded[0].track, new.track)
        XCTAssertEqual(reloaded[0].averageSpeed, 5)
        let document = try JSONDecoder().decode(RideStore.Document.self, from: Data(contentsOf: file))
        XCTAssertEqual(document.schemaVersion, 1)
        let resources = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resources.isExcludedFromBackup, true)
    }

    func testRenameFallbackDeleteAndReloadOnlyAffectsChosenRecord() async throws {
        let store = RideStore(fileURL: file)
        let first = record(), second = record(100)
        try await store.append(first)
        try await store.append(second)
        let renamed = try await store.updateName(id: first.id, name: "  Evening ride  ")
        XCTAssertEqual(renamed.last?.name, "Evening ride")
        XCTAssertEqual(renamed.last?.id, first.id)
        let fallback = try await store.updateName(id: first.id, name: " \n ")
        XCTAssertNil(fallback.last?.name)
        XCTAssertFalse(try XCTUnwrap(fallback.last).displayName.isEmpty)
        let remaining = try await store.delete(id: first.id)
        XCTAssertEqual(remaining, [second])
        let reloaded = try await RideStore(fileURL: file).load()
        XCTAssertEqual(reloaded, [second])
        let absentDelete = try await store.delete(id: first.id)
        XCTAssertEqual(absentDelete, [second])
        do { _ = try await store.updateName(id: first.id, name: "Gone"); XCTFail("Expected missing ID") }
        catch { XCTAssertTrue(error is RideStore.StoreError) }
    }

    func testEmptyMalformedFutureSchemaAndDuplicateIDsNeverOverwritten() async throws {
        let repeated = record()
        let duplicate = try JSONEncoder().encode(RideStore.Document(schemaVersion: 1, records: [repeated, repeated]))
        let future = try JSONEncoder().encode(RideStore.Document(schemaVersion: 2, records: []))
        for data in [Data(), Data("broken JSON".utf8), future, duplicate] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            let store = RideStore(fileURL: file)
            do { _ = try await store.load(); XCTFail("Expected read error") } catch {}
            let records = await store.records
            XCTAssertTrue(records.isEmpty)
            do { _ = try await store.append(record()); XCTFail("Must retain unreadable file") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testFailedEncodingLeavesPriorAtomicFileAndMemoryIntact() async throws {
        let store = RideStore(fileURL: file)
        let good = record()
        try await store.append(good)
        let bytes = try Data(contentsOf: file)
        let invalid = RideRecord(startedAt: Date(), endedAt: Date(), elapsedTime: 0,
                                 movingTime: 0, distance: .nan, maxSpeed: nil, track: [])
        do { _ = try await store.append(invalid); XCTFail("Expected encoding failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let memory = await store.records
        XCTAssertEqual(memory, [good])
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["history.json"])
    }

    func testWriteFailureDoesNotPublishAndCanRetry() async throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file instead of directory".utf8).write(to: blocked)
        let store = RideStore(fileURL: blocked.appendingPathComponent("history.json"))
        let ride = record()
        do { _ = try await store.append(ride); XCTFail("Expected disk error") } catch {}
        let memory = await store.records
        XCTAssertTrue(memory.isEmpty)
        try FileManager.default.removeItem(at: blocked)
        let saved = try await store.append(ride)
        XCTAssertEqual(saved, [ride])
    }

    func testZeroMovingTimeAndContiguousSegmentMapGeometry() async throws {
        let ride = record(movingTime: 0)
        XCTAssertNil(ride.averageSpeed)
        XCTAssertEqual(RideDisplayFormat.speed(ride.averageSpeed), "--")
        let store = RideStore(fileURL: file)
        try await store.append(ride)
        let saved = try await RideStore(fileURL: file).load()
        XCTAssertNil(saved[0].averageSpeed)
        XCTAssertEqual(saved[0].track, ride.track)
        let segments = RideRouteGeometry.segments(saved[0].track)
        XCTAssertEqual(segments.map(\.count), [2, 2])
        XCTAssertEqual(segments.map { $0[0].segment }, [0, 1])
        XCTAssertTrue(RideRouteGeometry.segments([]).isEmpty)
        XCTAssertTrue(RideRouteGeometry.segments([point(0, segment: 0)]).isEmpty)
        XCTAssertTrue(RideRouteGeometry.segments([point(0, segment: 0), point(2, segment: 1)]).isEmpty)
    }
}
