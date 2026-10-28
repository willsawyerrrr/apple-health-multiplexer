import Foundation

/// The household's shared copy of the readings.
protocol HouseholdSync: AnyObject {
    /// Uploads a reading. Uploading one the household already holds succeeds.
    func upload(_ reading: SyncReading) async throws
    /// Readings changed since the previous fetch.
    func fetchChanges() async throws -> [SyncReading]
}

/// Persists every attributed reading on receipt, uploads the outbox, and merges household readings.
@MainActor
final class ReadingSyncCoordinator {
    private let store: ReadingStore
    private let sync: HouseholdSync
    private var isFlushing = false

    init(store: ReadingStore, sync: HouseholdSync) {
        self.store = store
        self.sync = sync
    }

    /// Readings persisted on this phone, including those fetched from the household.
    var storedReadings: [ThermometerReading] { store.all.map(\.reading) }

    /// Persists a reading for upload; unattributed readings are dropped.
    func record(_ reading: ThermometerReading) {
        guard let reading = SyncReading(reading) else { return }
        store.add(reading, uploaded: false)
    }

    /// Uploads the outbox, stopping at the first failure; returns whether it is empty.
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing else { return false }
        isFlushing = true
        defer { isFlushing = false }
        for reading in store.pending {
            do { try await sync.upload(reading) } catch { return false }
            store.markUploaded([reading.recordName])
        }
        return true
    }

    /// Stores household readings not yet held locally and returns them.
    func pull() async throws -> [ThermometerReading] {
        try await sync.fetchChanges()
            .filter { store.add($0, uploaded: true) }
            .map(\.reading)
    }
}
