import Foundation
import SwiftUI
import XCTest
@testable import Waymate

private enum RideExportSample {
    static func point(_ latitude: Double, _ longitude: Double, _ seconds: Double = 0, segment: Int = 0) -> RideTrackPoint {
        .init(latitude: latitude, longitude: longitude, timestamp: Date(timeIntervalSince1970: 1_791_330_000 + seconds),
              horizontalAccuracy: 3, speed: 7, segment: segment)
    }
    static func record(track: [RideTrackPoint] = [point(36, 117), point(36.01, 117.02, 2)],
                       name: String? = "Morning Ride", moving: Double = 2_538, maxSpeed: Double? = 15.2) -> RideRecord {
        .init(name: name, startedAt: Date(timeIntervalSince1970: 1_791_330_000),
              endedAt: Date(timeIntervalSince1970: 1_791_333_000), elapsedTime: 3_000,
              movingTime: moving, distance: 18_400, maxSpeed: maxSpeed, track: track)
    }
}

final class RideShareRendererTests: XCTestCase {
    private let size = CGSize(width: 484, height: 210)

    func testEmptySinglePointAndSeparateSingletonsHaveNoDrawableRoute() {
        for track in [[], [RideExportSample.point(36, 117)],
                      [RideExportSample.point(36, 117), RideExportSample.point(37, 118, segment: 1)]] {
            XCTAssertTrue(RideShareRoute.project(track, into: size).isEmpty)
        }
    }

    func testOneSegmentAndMultipleSegmentsRetainAllVerticesAndPathBreaks() {
        let points = [RideExportSample.point(36, 117), RideExportSample.point(36.01, 117.02, 2),
                      RideExportSample.point(37, 118, 30, segment: 1), RideExportSample.point(37.01, 118.02, 32, segment: 1)]
        let segments = RideShareRoute.project(points, into: size)
        XCTAssertEqual(segments.map(\.count), [2, 2])
        var moves = 0, lines = 0
        RideShareRoute.path(segments).forEach { element in
            switch element { case .move: moves += 1; case .line: lines += 1; default: XCTFail("Unexpected curve") }
        }
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(lines, 2, "No third line connecting pause/GPS gaps")
        XCTAssertEqual(RideShareRoute.project(Array(points.prefix(2)), into: size).map(\.count), [2])
    }

    func testPortraitLandscapeAndLongRoutesFitPaddingWithOneUniformScale() throws {
        for end in [(36.1, 117.001), (36.001, 117.1), (55.0, 130.0)] {
            let track = [RideExportSample.point(36, 117), RideExportSample.point(end.0, end.1)]
            let points = try XCTUnwrap(RideShareRoute.project(track, into: size).first)
            for p in points {
                XCTAssertGreaterThanOrEqual(p.x, 24 - 0.000001)
                XCTAssertLessThanOrEqual(p.x, size.width - 24 + 0.000001)
                XCTAssertGreaterThanOrEqual(p.y, 24 - 0.000001)
                XCTAssertLessThanOrEqual(p.y, size.height - 24 + 0.000001)
            }
            let expectedRatio = abs((end.1 - 117) * .pi / 180)
                / abs(asinh(tan(end.0 * .pi / 180)) - asinh(tan(36 * .pi / 180)))
            XCTAssertEqual(abs(points[1].x - points[0].x) / abs(points[1].y - points[0].y), expectedRatio, accuracy: 0.000001)
            XCTAssertEqual((points[0].x + points[1].x) / 2, size.width / 2, accuracy: 0.000001)
            XCTAssertEqual((points[0].y + points[1].y) / 2, size.height / 2, accuracy: 0.000001)
        }
    }

    func testVeryShortAndStationaryRoutesStayFiniteAndSmall() throws {
        for latitude in [36.0, 36.000001] {
            let projected = try XCTUnwrap(RideShareRoute.project(
                [RideExportSample.point(36, 117), RideExportSample.point(latitude, 117)], into: size).first)
            XCTAssertTrue(projected.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            XCTAssertLessThan(abs(projected[1].y - projected[0].y), 1)
        }
    }

    func testDateLineUnwrapKeepsLocalTrackRatherThanWorldSpanningLine() throws {
        let points = try XCTUnwrap(RideShareRoute.project(
            [RideExportSample.point(0, 179.999), RideExportSample.point(0.001, -179.999)], into: size).first)
        XCTAssertEqual(abs(points[1].x - points[0].x) / abs(points[1].y - points[0].y), 2, accuracy: 0.00001)
    }

    func testInvalidCoordinateBreaksPathAndPolesDoNotProduceInfinity() {
        let track = [RideExportSample.point(36, 117), RideExportSample.point(.nan, 117),
                     RideExportSample.point(36.01, 117.01), RideExportSample.point(36.02, 117.02),
                     RideExportSample.point(90, 117)]
        XCTAssertEqual(RideShareRoute.project(track, into: size).map(\.count), [2])
        XCTAssertTrue(RideShareRoute.project(track, into: .zero).isEmpty)
    }

    @MainActor func testNormalCardProducesNonemptyHighResolutionImage() throws {
        try checkImage(RideExportSample.record(), name: "Stage 6 — normal card")
    }

    @MainActor func testNilAverageAndMaxRemainUnavailableAndMetricsCardStillRenders() throws {
        let record = RideExportSample.record(track: [], moving: 0, maxSpeed: nil)
        XCTAssertNil(record.averageSpeed)
        XCTAssertEqual(RideDisplayFormat.speed(record.averageSpeed), "--")
        XCTAssertEqual(RideDisplayFormat.speed(record.maxSpeed), "--")
        try checkImage(record, name: "Stage 6 — route unavailable and nil metrics")
    }

    @MainActor func testUnicodeAndLongNamesRenderAtTargetSize() throws {
        for name in ["乌鲁木齐 · 夜骑 🚲", String(repeating: "很长的骑行名称 Ride 🚲 ", count: 30)] {
            let record = RideExportSample.record(name: name)
            XCTAssertEqual(record.displayName, name.trimmingCharacters(in: .whitespacesAndNewlines))
            try checkImage(record, name: "Stage 6 — \(name.prefix(12))")
        }
    }

    @MainActor func testSevenThousandPointsUseSinglePathAndRender() throws {
        let track = (0..<7_200).map { index in
            RideExportSample.point(36 + Double(index) * 0.00001,
                                   117 + sin(Double(index) / 500) * 0.03, Double(index) * 2,
                                   segment: index / 1_800)
        }
        let start = Date()
        let projected = RideShareRoute.project(track, into: size)
        XCTAssertEqual(projected.map(\.count), [1_800, 1_800, 1_800, 1_800])
        try checkImage(RideExportSample.record(track: track), name: "Stage 6 — 7200 points, four segments")
        let attachment = XCTAttachment(string: "7200-point projection + image + PNG: \(Date().timeIntervalSince(start)) seconds")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func checkImage(_ record: RideRecord, name: String) throws {
        let image = try RideShareRenderer.image(for: record)
        XCTAssertEqual(image.scale, 2)
        XCTAssertEqual(image.cgImage?.width, 1080)
        XCTAssertEqual(image.cgImage?.height, 1350)
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 1_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class GPXProbe: NSObject, XMLParserDelegate {
    var root: [String: String] = [:]
    var namespace: String?
    var segments: [[(Double, Double)]] = []
    var times: [String] = []
    var names: [String] = []
    var elements: [String] = []
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements.append(elementName); text = ""
        if elementName == "gpx" { root = attributes; namespace = namespaceURI }
        if elementName == "trkseg" { segments.append([]) }
        if elementName == "trkpt", let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? ""), !segments.isEmpty {
            segments[segments.count - 1].append((lat, lon))
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "time" { times.append(text) }
        if elementName == "name" { names.append(text) }
        text = ""
    }
}

final class RideGPXExporterTests: XCTestCase {
    private func parse(_ data: Data) throws -> GPXProbe {
        let probe = GPXProbe(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = probe
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse failed")
        return probe
    }

    func testGPX11NamespaceCreatorActualCoordinatesAndUTCTimestamps() throws {
        let ride = RideExportSample.record()
        let data = try RideGPXExporter.data(for: ride), probe = try parse(data)
        XCTAssertEqual(probe.root["version"], "1.1")
        XCTAssertEqual(probe.root["creator"], "Waymate")
        XCTAssertEqual(probe.namespace, "http://www.topografix.com/GPX/1/1")
        XCTAssertEqual(probe.segments.map(\.count), [2])
        XCTAssertEqual(probe.names, [ride.displayName, ride.displayName])
        for (exported, original) in zip(probe.segments.flatMap { $0 }, ride.track) {
            XCTAssertEqual(exported.0, original.latitude)
            XCTAssertEqual(exported.1, original.longitude)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (time, date) in zip(probe.times, [ride.startedAt] + ride.track.map(\.timestamp)) {
            XCTAssertEqual(try XCTUnwrap(formatter.date(from: time)).timeIntervalSince1970,
                           date.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertTrue(time.hasSuffix("Z"))
        }
        XCTAssertEqual(probe.times.count, 3)
        XCTAssertFalse(probe.elements.contains("ele"))
        XCTAssertFalse(probe.elements.contains("speed"))
        XCTAssertFalse(probe.elements.contains("extensions"))
    }

    func testPauseAndGPSGapSegmentsPreservePointOrderingIncludingSingletons() throws {
        let track = [RideExportSample.point(36, 117), RideExportSample.point(36.001, 117, 2),
                     RideExportSample.point(37, 118, 40, segment: 1),
                     RideExportSample.point(38, 119, 80, segment: 2), RideExportSample.point(38.001, 119, 82, segment: 2)]
        let ride = RideExportSample.record(track: track)
        let probe = try parse(RideGPXExporter.data(for: ride))
        XCTAssertEqual(probe.segments.map(\.count), [2, 1, 2])
        XCTAssertEqual(probe.segments.flatMap { $0 }.map { $0.0 }, track.map(\.latitude))
        XCTAssertEqual(probe.segments.flatMap { $0 }.map { $0.1 }, track.map(\.longitude))
    }

    func testSpecialCharactersAndUnicodeNameRoundTripThroughXMLParser() throws {
        let name = "乌鲁木齐 🚲 & < > \" ' / :"
        let data = try RideGPXExporter.data(for: RideExportSample.record(name: name))
        XCTAssertEqual(try parse(data).names, [name, name])
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        for entity in ["&amp;", "&lt;", "&gt;", "&quot;", "&apos;"] { XCTAssertTrue(xml.contains(entity)) }
    }

    func testFilenameSafeEvenWithUnicodeTraversalAndControlCharacters() {
        let ride = RideExportSample.record(name: "../骑行/:\\?*\"<>|\n\0")
        let filename = RideGPXExporter.filename(for: ride)
        XCTAssertTrue(filename.hasPrefix("Waymate-")); XCTAssertTrue(filename.hasSuffix("-Ride.gpx"))
        XCTAssertFalse(filename.contains(".."))
        XCTAssertEqual(filename.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|\n\0")).count, 1)
    }

    func testEmptyTrackAndInvalidCoordinatesOrTimestampFailWithoutPartialOutput() {
        XCTAssertThrowsError(try RideGPXExporter.data(for: RideExportSample.record(track: [])))
        for point in [RideExportSample.point(.nan, 117), RideExportSample.point(91, 117),
                      RideExportSample.point(36, 181), RideExportSample.point(36, 180),
                      RideExportSample.point(36, 117, .infinity)] {
            XCTAssertThrowsError(try RideGPXExporter.data(for: RideExportSample.record(track: [point])))
        }
        XCTAssertThrowsError(try RideGPXExporter.data(for: RideExportSample.record(name: "bad\0name")))
    }

    func testDecimalCoordinatesNoExponentAndDeterministicBytes() throws {
        let ride = RideExportSample.record(track: [RideExportSample.point(0.0000001, -0.0000001)])
        let data = try RideGPXExporter.data(for: ride)
        XCTAssertEqual(data, try RideGPXExporter.data(for: ride))
        let probe = try parse(data)
        XCTAssertEqual(probe.segments[0][0].0, ride.track[0].latitude)
        XCTAssertEqual(probe.segments[0][0].1, ride.track[0].longitude)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("lat=\"0.0000001\""))
    }

    func testTemporaryFileUsesGPXBytesAndCleanupRemovesOnlyOwnDirectory() throws {
        let ride = RideExportSample.record(name: "中文骑行")
        let file = try RideGPXExporter.temporaryFile(for: ride)
        defer { RideGPXExporter.removeTemporaryFile(file) }
        XCTAssertEqual(file.pathExtension, "gpx")
        XCTAssertEqual(try Data(contentsOf: file), try RideGPXExporter.data(for: ride))
        XCTAssertTrue(file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        RideGPXExporter.removeTemporaryFile(other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        RideGPXExporter.removeTemporaryFile(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testSevenThousandPointsExportAndParseWithoutLosingData() throws {
        let track = (0..<7_200).map { RideExportSample.point(36 + Double($0) / 100_000, 117, Double($0) * 2, segment: $0 / 1_800) }
        let ride = RideExportSample.record(track: track), start = Date()
        let data = try RideGPXExporter.data(for: ride)
        let exportSeconds = Date().timeIntervalSince(start)
        let probe = try parse(data)
        XCTAssertEqual(probe.segments.map(\.count), [1_800, 1_800, 1_800, 1_800])
        XCTAssertEqual(probe.segments.flatMap { $0 }.map { $0.0 }, track.map(\.latitude))
        let attachment = XCTAttachment(string: "7200-point GPX: \(data.count) bytes; export \(exportSeconds) seconds")
        attachment.lifetime = .keepAlways; add(attachment)
        let gpx = XCTAttachment(data: data, uniformTypeIdentifier: "public.xml")
        gpx.name = "Stage6-7200-points.gpx"; gpx.lifetime = .keepAlways; add(gpx)
    }
}
