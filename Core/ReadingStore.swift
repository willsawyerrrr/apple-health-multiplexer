import Foundation

/// Durable local storage of readings, with an outbox of those not yet uploaded.
protocol ReadingStore: AnyObject {
    /// Every stored reading.
    var all: [SyncReading] { get }
    /// Readings not yet uploaded, oldest first.
    var pending: [SyncReading] { get }
    /// Persists a reading; returns `false` when it was already stored.
    @discardableResult
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool
    func markUploaded(_ recordNames: [String])
}

/// A `ReadingStore` persisted as a JSON file, rewritten atomically on every change.
final class FileReadingStore: ReadingStore {
    private struct Entry: Codable {
        var reading: SyncReading
        var uploaded: Bool
    }

    private let url: URL
    private var entries: [Entry]

    init(url: URL) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    var all: [SyncReading] { entries.map(\.reading) }

    var pending: [SyncReading] {
        entries.filter { !$0.uploaded }.map(\.reading).sorted { $0.measuredAt < $1.measuredAt }
    }

    @discardableResult
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool {
        guard !entries.contains(where: { $0.reading.recordName == reading.recordName }) else { return false }
        entries.append(Entry(reading: reading, uploaded: uploaded))
        persist()
        return true
    }

    func markUploaded(_ recordNames: [String]) {
        let names = Set(recordNames)
        for index in entries.indices where names.contains(entries[index].reading.recordName) {
            entries[index].uploaded = true
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
