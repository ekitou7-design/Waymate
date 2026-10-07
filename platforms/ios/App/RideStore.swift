import Foundation
import OSLog

/// All disk access/JSON work is actor-isolated, away from the UI thread.
// ponytail: one document loads/rewrites the full history; use per-ride files if large histories demand it.
actor RideStore {
    static let defaultFileURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
        .appendingPathComponent("Waymate/Rides/history-v1.json")
    struct Document: Codable {
        let schemaVersion: Int
        let records: [RideRecord]
    }

    enum StoreError: LocalizedError {
        case unsupportedSchema(Int), duplicateIdentity, recordNotFound

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version): return "不支持的 Ride 历史版本：\(version)"
            case .duplicateIdentity: return "Ride 历史包含重复 ID"
            case .recordNotFound: return "找不到这次 Ride"
            }
        }
    }

    private let fileURL: URL
    private(set) var records: [RideRecord] = []
    private var loaded = false
    private var readError: Error?
    private let logger = Logger(subsystem: "com.zhengxiaohua.waymate", category: "RideStore")

    init(fileURL: URL = RideStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    @discardableResult
    func load() throws -> [RideRecord] {
        if loaded {
            if let readError { throw readError }
            return records
        }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.schemaVersion == 1 else {
                throw StoreError.unsupportedSchema(document.schemaVersion)
            }
            guard Set(document.records.map(\.id)).count == document.records.count else {
                throw StoreError.duplicateIdentity
            }
            records = Self.sorted(document.records)
            return records
        } catch {
            readError = error
            records = []
            logger.error("Ride history read failed; original file retained: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    @discardableResult
    func append(_ record: RideRecord) throws -> [RideRecord] {
        try load()
        guard !records.contains(where: { $0.id == record.id }) else { return records }
        return try write(records + [record])
    }

    @discardableResult
    func updateName(id: UUID, name: String) throws -> [RideRecord] {
        try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw StoreError.recordNotFound }
        var updated = records
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].name = trimmed.isEmpty ? nil : trimmed
        return try write(updated)
    }

    @discardableResult
    func delete(id: UUID) throws -> [RideRecord] {
        try load()
        guard records.contains(where: { $0.id == id }) else { return records }
        return try write(records.filter { $0.id != id })
    }

    private func write(_ updated: [RideRecord]) throws -> [RideRecord] {
        let sorted = Self.sorted(updated)
        do {
            let data = try JSONEncoder().encode(Document(schemaVersion: 1, records: sorted))
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // These records are local-only, including exclusion from system backups.
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            try data.write(to: fileURL, options: .atomic)
            // Publish only after the atomic replacement succeeds.
            records = sorted
            return records
        } catch {
            logger.error("Ride history write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func sorted(_ records: [RideRecord]) -> [RideRecord] {
        records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
