import Foundation
import XCTest
@testable import MotoNavigationCore

final class WaymateDefaultsTests: XCTestCase {
    func testMigratesAllLegacyKeysAndPrefersCurrentValues() throws {
        let suite = "WaymateMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for suffix in ["RecentPlaces.v1", "KnownPeripheralIdentifier", "GatewayBaseURL.v1"] {
            let key = "Waymate.\(suffix)"
            let legacy = "MotoGPS.\(suffix)"
            defaults.set("old", forKey: legacy)
            XCTAssertEqual(WaymateDefaults.value(forKey: key, legacyKey: legacy, defaults: defaults) { $0 as? String }, "old")
            XCTAssertEqual(defaults.string(forKey: key), "old")
            XCTAssertEqual(defaults.string(forKey: legacy), "old")
            defaults.set("new", forKey: key)
            XCTAssertEqual(WaymateDefaults.value(forKey: key, legacyKey: legacy, defaults: defaults) { $0 as? String }, "new")
        }
    }

    func testCopiesOnlySuccessfullyDecodedDataAndDoesNotFallbackWhenNewKeyExists() throws {
        let suite = "WaymateMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let decode: (Any) -> [String]? = { value in
            (value as? Data).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        }
        defaults.set(Data("invalid".utf8), forKey: "legacy")
        XCTAssertNil(WaymateDefaults.value(forKey: "current", legacyKey: "legacy", defaults: defaults, decode: decode))
        XCTAssertNil(defaults.object(forKey: "current"))
        let data = try JSONEncoder().encode(["saved place"])
        defaults.set(data, forKey: "legacy")
        XCTAssertEqual(WaymateDefaults.value(forKey: "current", legacyKey: "legacy", defaults: defaults, decode: decode), ["saved place"])
        XCTAssertEqual(defaults.data(forKey: "current"), data)
        defaults.set(Data("invalid".utf8), forKey: "current")
        XCTAssertNil(WaymateDefaults.value(forKey: "current", legacyKey: "legacy", defaults: defaults, decode: decode))
    }

    func testGatewayMigratesValidLegacyAddress() throws {
        let suite = "WaymateMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://own.example.com/api", forKey: GatewayConfiguration.legacyDefaultsKey)
        XCTAssertEqual(GatewayConfiguration.resolvedURL(defaults: defaults, bundledAddress: nil)?.absoluteString,
                       "https://own.example.com/api/")
        XCTAssertEqual(defaults.string(forKey: GatewayConfiguration.defaultsKey), "https://own.example.com/api")
    }
}
