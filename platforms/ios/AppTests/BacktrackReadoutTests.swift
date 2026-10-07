import XCTest
@testable import Waymate

final class BacktrackReadoutTests: XCTestCase {
    func testLocationWarningsHideDirectionAndNeverInventRerouting() {
        for validity in [BacktrackLocationValidity.waiting, .poorAccuracy, .stale, .jumpRejected, .unavailable] {
            let p = BacktrackProgress(targetBearing: 180, offTrack: true, locationValidity: validity)
            let readout = BacktrackReadout(progress: p, paused: false)
            XCTAssertFalse(readout.canGuide)
            XCTAssertNotEqual(readout.status, "REROUTING")
            XCTAssertNotEqual(readout.status, "OFF TRACK")
        }
    }
    func testPauseGapArrivalAndActualDistances() {
        var p = BacktrackProgress(offTrack: true, trailGap: true, locationValidity: .usable)
        XCTAssertEqual(BacktrackReadout(progress: p, paused: true).status, "RIDE PAUSED")
        XCTAssertEqual(BacktrackReadout(progress: p, paused: false).status, "TRAIL GAP")
        p.trailGap = false
        XCTAssertEqual(BacktrackReadout(progress: p, paused: false).status, "OFF TRACK")
        p.arrived = true
        XCTAssertEqual(BacktrackReadout(progress: p, paused: false).status, "START REACHED")
        XCTAssertFalse(BacktrackReadout(progress: p, paused: false).canGuide)
        XCTAssertEqual(BacktrackReadout.distance(nil), "--")
        XCTAssertEqual(BacktrackReadout.distance(42), "42 m")
        XCTAssertEqual(BacktrackReadout.distance(2_400), "2.4 km")
    }
    func testMapCompletionSplitsAtActualMatchedPosition() throws {
        var s = BacktrackSession(route: try BacktrackTestTrail.route())
        BacktrackTestTrail.feed(&s, 100, time: 0)
        BacktrackTestTrail.feed(&s, 85, time: 2)
        let lines = BacktrackMapGeometry(route: s.route, progress: s.progress).completed
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].first, BacktrackTestTrail.point(100))
        XCTAssertLessThan(BreadcrumbMath.distance(lines[0].last!, BacktrackTestTrail.point(85)), 0.01)
        XCTAssertEqual(s.route.segments[0].points.last, BacktrackTestTrail.point(0))
    }
}
