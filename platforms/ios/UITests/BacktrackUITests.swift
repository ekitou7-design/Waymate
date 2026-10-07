import CoreLocation
import XCTest

final class BacktrackUITests: XCTestCase {
    private var previousLocation: XCUILocation?
    override func setUpWithError() throws {
        continueAfterFailure = false
        previousLocation = XCUIDevice.shared.location
        emit(north: 0)
    }
    override func tearDownWithError() throws { XCUIDevice.shared.location = previousLocation }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--moto-ui-offline", "--waymate-ui-ride-store", UUID().uuidString]
        app.launch()
        return app
    }
    // All simulated observations stay in XCTest and enter the real Core Location → Ride chain.
    private func emit(north: Double, east: Double = 0) {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            coordinate: .init(latitude: 36.6748039 + north / 111_000,
                              longitude: 117.1224488 + east / 89_000), altitude: 0,
            horizontalAccuracy: 3, verticalAccuracy: 3, course: 180, speed: 8, timestamp: Date()))
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }
    private func recordTrail(_ app: XCUIApplication) {
        app.buttons["ride-start-button"].tap()
        XCTAssertTrue(app.buttons["ride-end-button"].waitForExistence(timeout: 10))
        for north in [0.0, 30, 60, 90] { emit(north: north); sleep(3) }
        let start = app.buttons["backtrack-start-button"]
        reveal(start, app)
        XCTAssertTrue(start.isEnabled)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDisabledWithoutEnoughTrailAndPausedReason() {
        let app = launch()
        app.buttons["ride-start-button"].tap()
        XCTAssertTrue(app.buttons["backtrack-start-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["backtrack-start-button"].isEnabled)
        XCTAssertTrue(app.staticTexts["Not enough ride history yet"].exists)
        reveal(app.buttons["ride-pause-button"], app)
        app.buttons["ride-pause-button"].tap()
        XCTAssertFalse(app.buttons["backtrack-start-button"].isEnabled)
        XCTAssertTrue(app.staticTexts["Resume Ride to start Backtrack"].exists)
    }
    func testActualTrailBacktrackOffTrackEndRideContinuesAndHistoryHasNoBacktrack() {
        let app = launch()
        recordTrail(app)
        app.buttons["backtrack-start-button"].tap()
        XCTAssertTrue(app.navigationBars["原路返回"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["FOLLOW TRAIL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["backtrack-remaining-distance"].exists)
        screenshot(app, "Backtrack — actual simulator trail")
        emit(north: 90, east: 45)
        XCTAssertTrue(app.staticTexts["OFF TRACK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["RETURN TO TRAIL"].exists)
        screenshot(app, "Backtrack — off track from XCTest location")
        emit(north: 90)
        XCTAssertTrue(app.staticTexts["FOLLOW TRAIL"].waitForExistence(timeout: 10))
        reveal(app.buttons["backtrack-end-button"], app)
        app.buttons["backtrack-end-button"].tap()
        XCTAssertTrue(app.buttons["ride-end-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ride-start-button"].exists)
        reveal(app.buttons["ride-end-button"], app)
        app.swipeUp()
        app.buttons["ride-end-button"].tap()
        app.buttons["结束 Ride"].tap()
        XCTAssertTrue(app.buttons["ride-summary-done"].waitForExistence(timeout: 10))
        let done = app.buttons["ride-summary-done"]
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        reveal(app.buttons["ride-history-button"], app)
        app.buttons["ride-history-button"].tap()
        let row = app.collectionViews["ride-history-list"].buttons.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Ride Detail"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["backtrack-start-button"].exists)
        screenshot(app, "Backtrack — history has no start action")
    }
    func testBothNavigationConflictConfirmationsKeepRideActive() {
        let app = launch()
        recordTrail(app)
        if !app.buttons["demo-navigation-button"].exists {
            reveal(app.buttons["更多"], app); app.buttons["更多"].tap()
        }
        reveal(app.buttons["demo-navigation-button"], app); app.buttons["demo-navigation-button"].tap()
        XCTAssertTrue(app.navigationBars["演示导航"].waitForExistence(timeout: 5))
        reveal(app.buttons["backtrack-start-button"], app); app.buttons["backtrack-start-button"].tap()
        XCTAssertTrue(app.staticTexts["开始原路返回将结束当前导航。"].waitForExistence(timeout: 5))
        screenshot(app, "Backtrack — explicit navigation replacement")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["演示导航"].exists)
        app.buttons["backtrack-start-button"].tap()
        app.buttons["确认切换"].tap()
        XCTAssertTrue(app.navigationBars["原路返回"].waitForExistence(timeout: 5))
        reveal(app.buttons["backtrack-navigate-button"], app); app.buttons["backtrack-navigate-button"].tap()
        XCTAssertTrue(app.buttons["backtrack-start-button"].waitForExistence(timeout: 5))
        if !app.buttons["demo-navigation-button"].exists {
            reveal(app.buttons["更多"], app); app.buttons["更多"].tap()
        }
        reveal(app.buttons["demo-navigation-button"], app); app.buttons["demo-navigation-button"].tap()
        XCTAssertTrue(app.staticTexts["开始普通导航将结束原路返回。"].waitForExistence(timeout: 5))
        screenshot(app, "Backtrack — explicit normal navigation replacement")
        app.buttons["确认切换"].tap()
        XCTAssertTrue(app.navigationBars["演示导航"].waitForExistence(timeout: 5))
        app.buttons["primary-navigation-action"].tap()
        XCTAssertTrue(app.buttons["ride-end-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ride-start-button"].exists)
    }
}
