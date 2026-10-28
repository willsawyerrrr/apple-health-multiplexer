import Foundation

/// Durable local storage of readings, with an outbox of those not yet uploaded.
protocol ReadingStore: AnyObject {
    /// Every stored reading.
    var all: [SyncReading] { get }
    /// Readings not yet uploaded, oldest first.
    var pending: [SyncReading] { get }
    /// Persists a reading; returns `false` when it was already stored or was deleted.
    @discardableResult
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool
    /// Whether the reading was deleted on this phone.
    func isDeleted(_ recordName: String) -> Bool
    /// Removes the reading, including from the outbox, and remembers its name so `add` refuses it from then on.
    func delete(_ recordName: String)
    func markUploaded(_ recordNames: [String])
}

/// A `ReadingStore` persisted as a JSON file, rewritten atomically on every change.
/// Deleted record names are kept so a deleted reading is never stored again.
final class FileReadingStore: ReadingStore {
    private struct Entry: Codable {
        var reading: SyncReading
        var uploaded: Bool
    }

    private struct Snapshot: Codable {
        var entries: [Entry]
        var deleted: Set<String>
    }

    private let url: URL
    private var entries: [Entry]
    private var deleted: Set<String>

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        if let snapshot = data.flatMap({ try? JSONDecoder().decode(Snapshot.self, from: $0) }) {
            entries = snapshot.entries
            deleted = snapshot.deleted
        } else {
            entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
            deleted = []
        }
    }

    var all: [SyncReading] { entries.map(\.reading) }

    var pending: [SyncReading] {
        entries.filter { !$0.uploaded }.map(\.reading).sorted { $0.measuredAt < $1.measuredAt }
    }

    @discardableResult
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool {
        guard !deleted.contains(reading.recordName),
            !entries.contains(where: { $0.reading.recordName == reading.recordName })
        else { return false }
        entries.append(Entry(reading: reading, uploaded: uploaded))
        persist()
        return true
    }

    func isDeleted(_ recordName: String) -> Bool { deleted.contains(recordName) }

    func delete(_ recordName: String) {
        entries.removeAll { $0.reading.recordName == recordName }
        deleted.insert(recordName)
        persist()
    }

    func markUploaded(_ recordNames: [String]) {
        let names = Set(recordNames)
        for index in entries.indices where names.contains(entries[index].reading.recordName) {
            entries[index].uploaded = true
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(entries: entries, deleted: deleted)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
