import Foundation
import MotoNavigationCore
import XCTest
@testable import Waymate

@MainActor
final class RideHistoryIntegrationTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("history.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testEndPersistsExactlyOnceNewRideIDLastRecordAndStartupLoad() async throws {
        let store = RideStore(fileURL: file)
        let model = AppModel(startsServices: false, locationSource: HistoryLocationSource(), rideStore: store)
        model.startRide(); model.stopRide(); model.stopRide()
        let first = try XCTUnwrap(model.rideRecord)
        XCTAssertNil(model.lastRideRecord) // Stop → save attempt → publish last → Summary.
        await model.waitForRidePersistence()
        XCTAssertEqual(model.rideHistory, [first])
        XCTAssertEqual(model.lastRideRecord, first)
        XCTAssertEqual(model.rideSummaryID, first.id)
        XCTAssertTrue(model.savingRideIDs.isEmpty)
        XCTAssertTrue(model.rideSaveErrors.isEmpty)
        model.rideSummaryID = nil
        model.startRide(); model.stopRide()
        let second = try XCTUnwrap(model.rideRecord)
        XCTAssertNotEqual(first.id, second.id)
        await model.waitForRidePersistence()
        XCTAssertEqual(model.rideHistory.count, 2)
        XCTAssertEqual(model.rideHistory.first, second)
        let relaunched = AppModel(startsServices: false, rideStore: RideStore(fileURL: file))
        await relaunched.waitForRidePersistence()
        XCTAssertEqual(relaunched.rideHistory, model.rideHistory)
        XCTAssertFalse(relaunched.rideActive)
        XCTAssertNil(relaunched.lastRideRecord)
    }

    func testNavigationContinuesAndSummaryDoesNotAutoPresent() async throws {
        let source = HistoryLocationSource()
        let model = AppModel(startsServices: false, locationSource: source, rideStore: RideStore(fileURL: file))
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117, latitudeDeg: 36), routeProvider: HistoryRouteProvider())
        XCTAssertTrue(model.rideActive)
        model.stopRide(); model.stopRide()
        await model.waitForRidePersistence()
        XCTAssertEqual(model.rideHistory, [try XCTUnwrap(model.lastRideRecord)])
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertNil(model.rideSummaryID)
        XCTAssertEqual(source.stops, 0)
        model.rideSummaryID = model.lastRideRecord?.id
        XCTAssertTrue(model.isNavigationActive)
        model.stopNavigation()
        XCTAssertEqual(source.stops, 1)
    }

    func testPersistenceFailureStillEndsRideAndRetainsRealRecordThenRetry() async throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let store = RideStore(fileURL: blocked.appendingPathComponent("history.json"))
        let model = AppModel(startsServices: false, locationSource: HistoryLocationSource(), rideStore: store)
        model.startRide(); model.stopRide()
        let record = try XCTUnwrap(model.rideRecord)
        await model.waitForRidePersistence()
        XCTAssertFalse(model.rideActive)
        XCTAssertEqual(model.rideRecord, record)
        XCTAssertEqual(model.rideSummaryID, record.id)
        XCTAssertNotNil(model.rideSaveErrors[record.id])
        XCTAssertTrue(model.rideHistory.isEmpty)
        try FileManager.default.removeItem(at: blocked)
        model.retryRideSave(id: record.id); model.retryRideSave(id: record.id)
        await model.waitForRidePersistence()
        XCTAssertNil(model.rideSaveErrors[record.id])
        XCTAssertEqual(model.rideHistory, [record])
        XCTAssertEqual(model.lastRideRecord, record)
    }

    func testRenameDeleteAndConcurrentEndStayConsistent() async throws {
        let model = AppModel(startsServices: false, locationSource: HistoryLocationSource(), rideStore: RideStore(fileURL: file))
        model.startRide(); model.stopRide()
        let id = try XCTUnwrap(model.rideRecord).id
        await model.waitForRidePersistence()
        try await model.renameRide(id: id, name: "Morning")
        XCTAssertEqual(model.lastRideRecord?.name, "Morning")
        XCTAssertEqual(model.savedRide(id: id)?.name, "Morning")
        model.rideSummaryID = nil
        model.startRide(); model.stopRide()
        let latest = try XCTUnwrap(model.rideRecord)
        try await model.deleteRide(id: id)
        await model.waitForRidePersistence()
        XCTAssertEqual(model.rideHistory, [latest])
        XCTAssertEqual(model.lastRideRecord, latest)
        let persisted = try await RideStore(fileURL: file).load()
        XCTAssertEqual(persisted, [latest])
        try await model.deleteRide(id: latest.id)
        XCTAssertTrue(model.rideHistory.isEmpty)
        XCTAssertNil(model.lastRideRecord)
        XCTAssertNil(model.rideSummaryID)
    }

    func testCorruptStartupEmptyErrorAndOriginalRetained() async throws {
        let bytes = Data("not JSON".utf8)
        try bytes.write(to: file)
        let model = AppModel(startsServices: false, locationSource: HistoryLocationSource(), rideStore: RideStore(fileURL: file))
        await model.waitForRidePersistence()
        XCTAssertFalse(model.rideHistoryLoading)
        XCTAssertTrue(model.rideHistory.isEmpty)
        XCTAssertNotNil(model.rideHistoryError)
        model.startRide(); model.stopRide()
        await model.waitForRidePersistence()
        XCTAssertNotNil(model.rideSaveErrors[try XCTUnwrap(model.lastRideRecord).id])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(model.rideActive)
    }

    func testRapidEndsPublishNewestAndCannotInterruptNewNavigation() async throws {
        let model = AppModel(startsServices: false, locationSource: HistoryLocationSource(), rideStore: RideStore(fileURL: file))
        model.startRide(); model.stopRide()
        let first = try XCTUnwrap(model.rideRecord)
        model.startRide(); model.stopRide()
        let second = try XCTUnwrap(model.rideRecord)
        model.beginLiveNavigation(destination: .init(longitudeDeg: 117, latitudeDeg: 36), routeProvider: HistoryRouteProvider())
        await model.waitForRidePersistence()
        XCTAssertEqual(Set(model.rideHistory.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(model.lastRideRecord, second)
        XCTAssertTrue(model.isNavigationActive)
        XCTAssertTrue(model.rideActive)
        XCTAssertNil(model.rideSummaryID)
        model.stopNavigation()
        model.pauseRide()
    }
}

@MainActor
private final class HistoryLocationSource: NavigationLocationSource {
    var stops = 0
    func start(onFix: @escaping @MainActor (NavigationFix) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {}
    func stop() { stops += 1 }
}
private struct HistoryRouteProvider: NavigationRouteProviding {
    func route(for request: RouteRequest) async throws -> RouteEnvelope {
        throw NavigationSourceError.unavailable("No fixes emitted")
    }
}
