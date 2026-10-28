import Foundation

/// What changed in the household's copy since the previous fetch.
struct HouseholdChanges: Equatable {
    var readings: [SyncReading] = []
    /// Record names of readings deleted from the household.
    var deletedRecordNames: [String] = []
}

/// What a pull changed on this phone.
struct HouseholdPull: Equatable {
    /// Household readings not held locally before.
    var added: [ThermometerReading] = []
    /// Record names the household deleted; they are gone from the store.
    var deletedRecordNames: [String] = []
}

/// The household's shared copy of the readings.
protocol HouseholdSync: AnyObject {
    /// Uploads a reading. Uploading one the household already holds succeeds.
    func upload(_ reading: SyncReading) async throws
    /// Deletes the household's copy of a reading for every member. Deleting one that is already gone succeeds.
    func delete(recordName: String) async throws
    /// Readings changed and deleted since the previous fetch.
    func fetchChanges() async throws -> HouseholdChanges
}

/// Persists every attributed reading on receipt, uploads the outbox, and merges household readings.
@MainActor
final class ReadingSyncCoordinator {
    private let store: ReadingStore
    private let sync: HouseholdSync
    private let isTracked: (Int) -> Bool
    private var isFlushing = false
    private var flushRequested = false

    /// `isTracked` says whether a profile slot's readings may be persisted and shared.
    init(store: ReadingStore, sync: HouseholdSync, isTracked: @escaping (Int) -> Bool = { _ in true }) {
        self.store = store
        self.sync = sync
        self.isTracked = isTracked
    }

    /// Readings persisted on this phone, including those fetched from the household.
    var storedReadings: [ThermometerReading] { store.all.map(\.reading) }

    /// Persists a reading for upload; unattributed readings and those of untracked profiles are dropped.
    func record(_ reading: ThermometerReading) {
        guard let reading = SyncReading(reading), isTracked(reading.profile) else { return }
        store.add(reading, uploaded: false)
    }

    /// Whether the reading was deleted on this phone and so must not be shown, stored or written again.
    func isDeleted(_ reading: ThermometerReading) -> Bool {
        SyncReading(reading).map { store.isDeleted($0.recordName) } ?? false
    }

    /// Deletes the reading from this phone's store and outbox, and queues the deletion of the household's
    /// copy if it was uploaded; `flush` carries it out. The deleted name stays remembered as a guard so
    /// an in-flight upload, a retry or a Bluetooth re-delivery cannot bring the reading back.
    func delete(_ reading: ThermometerReading) {
        guard let name = reading.recordName else { return }
        store.delete(name)
    }

    /// Deletes queued household copies, then uploads the outbox, each stopping at the first failure; returns
    /// whether both are empty. A call during a flush makes it run again once it finishes.
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing else {
            flushRequested = true
            return false
        }
        isFlushing = true
        defer { isFlushing = false }
        repeat {
            flushRequested = false
            guard await flushOnce() else { return false }
        } while flushRequested
        return true
    }

    private func flushOnce() async -> Bool {
        for name in store.pendingDeletions {
            do { try await sync.delete(recordName: name) } catch { return false }
            store.markDeletionsDone([name])
        }
        for reading in store.pending where !store.isDeleted(reading.recordName) {
            do { try await sync.upload(reading) } catch { return false }
            if store.isDeleted(reading.recordName) {
                store.queueDeletion(reading.recordName)
                flushRequested = true
            } else {
                store.markUploaded([reading.recordName])
            }
        }
        return true
    }

    /// Stores household readings not yet held locally and not deleted, removes those the household deleted,
    /// and returns both.
    func pull() async throws -> HouseholdPull {
        let changes = try await sync.fetchChanges()
        changes.deletedRecordNames.forEach(store.discard)
        let added = changes.readings.filter { store.add($0, uploaded: true) }.map(\.reading)
        return HouseholdPull(added: added, deletedRecordNames: changes.deletedRecordNames)
    }
}
