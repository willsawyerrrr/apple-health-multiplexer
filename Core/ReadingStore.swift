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
    /// Record names whose household copy still has to be deleted, oldest first.
    var pendingDeletions: [String] { get }
    /// Whether the reading was deleted, here or by the household.
    func isDeleted(_ recordName: String) -> Bool
    /// Removes the reading, including from the outbox, and remembers its name so `add` refuses it from then on.
    /// Queues the household copy's deletion when the reading was uploaded.
    func delete(_ recordName: String)
    /// Queues the household copy's deletion, for a reading that was deleted while its upload was in flight.
    func queueDeletion(_ recordName: String)
    /// Removes a reading the household deleted, and remembers its name so `add` refuses it from then on.
    /// Nothing is queued: the household copy is already gone.
    func discard(_ recordName: String)
    /// Forgets queued deletions the household copy no longer needs.
    func markDeletionsDone(_ recordNames: [String])
    func markUploaded(_ recordNames: [String])
}

/// A `ReadingStore` persisted as a JSON file, rewritten atomically on every change.
/// Deleted record names are kept as a guard so a deleted reading is never stored again, along with the
/// queue of household copies still to be deleted.
final class FileReadingStore: ReadingStore {
    private struct Entry: Codable {
        var reading: SyncReading
        var uploaded: Bool
    }

    private struct Snapshot: Codable {
        var entries: [Entry]
        var deleted: Set<String>
        var pendingDeletions: [String]

        init(entries: [Entry], deleted: Set<String>, pendingDeletions: [String]) {
            self.entries = entries
            self.deleted = deleted
            self.pendingDeletions = pendingDeletions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decode([Entry].self, forKey: .entries)
            deleted = try container.decode(Set<String>.self, forKey: .deleted)
            pendingDeletions = try container.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
        }
    }

    private let url: URL
    private var entries: [Entry]
    private var deleted: Set<String>
    private var queued: [String]

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        if let snapshot = data.flatMap({ try? JSONDecoder().decode(Snapshot.self, from: $0) }) {
            entries = snapshot.entries
            deleted = snapshot.deleted
            queued = snapshot.pendingDeletions
        } else {
            entries = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
            deleted = []
            queued = []
        }
    }

    var all: [SyncReading] { entries.map(\.reading) }

    var pending: [SyncReading] {
        entries.filter { !$0.uploaded }.map(\.reading).sorted { $0.measuredAt < $1.measuredAt }
    }

    var pendingDeletions: [String] { queued }

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
        let wasUploaded = entries.first { $0.reading.recordName == recordName }?.uploaded == true
        entries.removeAll { $0.reading.recordName == recordName }
        deleted.insert(recordName)
        if wasUploaded, !queued.contains(recordName) { queued.append(recordName) }
        persist()
    }

    func queueDeletion(_ recordName: String) {
        guard !queued.contains(recordName) else { return }
        queued.append(recordName)
        persist()
    }

    func discard(_ recordName: String) {
        entries.removeAll { $0.reading.recordName == recordName }
        deleted.insert(recordName)
        persist()
    }

    func markDeletionsDone(_ recordNames: [String]) {
        queued.removeAll { recordNames.contains($0) }
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
        guard let data = try? JSONEncoder().encode(Snapshot(entries: entries, deleted: deleted, pendingDeletions: queued)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
