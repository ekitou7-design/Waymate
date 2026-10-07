import Foundation

enum RideGPXExporter {
    enum ExportError: LocalizedError {
        case emptyTrack, invalidTrack, invalidName
        var errorDescription: String? {
            switch self {
            case .emptyTrack: return "没有实际 GPS 轨迹，无法导出 GPX。"
            case .invalidTrack: return "轨迹包含无效坐标或时间，无法导出 GPX。"
            case .invalidName: return "Ride 名称包含 XML 不支持的字符，无法导出 GPX。"
            }
        }
    }

    static func validate(_ record: RideRecord) throws {
        guard !record.track.isEmpty else { throw ExportError.emptyTrack }
        guard record.startedAt.timeIntervalSince1970.isFinite,
              record.track.allSatisfy({
                  $0.latitude.isFinite && (-90...90).contains($0.latitude)
                    && $0.longitude.isFinite && $0.longitude >= -180 && $0.longitude < 180
                    && $0.timestamp.timeIntervalSince1970.isFinite
              }) else { throw ExportError.invalidTrack }
    }

    static func data(for record: RideRecord) throws -> Data {
        try validate(record)
        let name = try escape(record.displayName)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = Data()
        data.reserveCapacity(record.track.count * 130 + name.utf8.count * 2 + 512)
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<gpx xmlns=\"http://www.topografix.com/GPX/1/1\" version=\"1.1\" creator=\"Waymate\">\n")
        append("<metadata><name>\(name)</name><time>\(formatter.string(from: record.startedAt))</time></metadata>\n")
        append("<trk><name>\(name)</name>\n")
        var segment: Int?
        for point in record.track {
            if segment != point.segment {
                if segment != nil { append("</trkseg>\n") }
                append("<trkseg>\n")
                segment = point.segment
            }
            // xs:decimal forbids scientific notation. Decimal expands Double's
            // shortest round-trip representation without a locale-dependent separator.
            let latitude = try decimal(point.latitude)
            let longitude = try decimal(point.longitude)
            append("<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\"><time>\(formatter.string(from: point.timestamp))</time></trkpt>\n")
        }
        append("</trkseg>\n</trk>\n</gpx>\n")
        return data
    }

    static func filename(for record: RideRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        // Date-only filename deliberately avoids user text, separators and traversal.
        return "Waymate-\(formatter.string(from: record.startedAt))-Ride.gpx"
    }

    private static func decimal(_ value: Double) throws -> String {
        guard let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN else { throw ExportError.invalidTrack }
        return decimal.description
    }

    private static func escape(_ text: String) throws -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 38: escaped += "&amp;"
            case 60: escaped += "&lt;"
            case 62: escaped += "&gt;"
            case 34: escaped += "&quot;"
            case 39: escaped += "&apos;"
            case 9, 10, 13, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                escaped.unicodeScalars.append(scalar)
            default: throw ExportError.invalidName
            }
        }
        return escaped
    }

    /// Only derived files under our own temporary root; RideStore is never written.
    static func temporaryFile(for record: RideRecord) throws -> URL {
        let data = try data(for: record)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("WaymateRideExports", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Clear crash leftovers after a day, never an active share's recent file.
        for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < Date().addingTimeInterval(-86_400) { try? manager.removeItem(at: url) }
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(filename(for: record))
        do { try data.write(to: file, options: .atomic); return file }
        catch { try? manager.removeItem(at: directory); throw error }
    }

    static func removeTemporaryFile(_ file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WaymateRideExports", isDirectory: true)
        guard file.deletingLastPathComponent().deletingLastPathComponent() == root else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
