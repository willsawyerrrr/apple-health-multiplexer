import CloudKit
import Foundation
import Testing

@testable import Kintemp

final class InMemoryReadingStore: ReadingStore {
    private var entries: [(reading: SyncReading, uploaded: Bool)] = []
    private(set) var pendingDeletions: [String] = []
    var all: [SyncReading] { entries.map(\.reading) }
    var pending: [SyncReading] {
        entries.filter { !$0.uploaded }.map(\.reading).sorted { $0.measuredAt < $1.measuredAt }
    }
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool {
        guard !deleted.contains(reading.recordName), !entries.contains(where: { $0.reading == reading }) else {
            return false
        }
        entries.append((reading, uploaded))
        return true
    }
    private var deleted: Set<String> = []
    func isDeleted(_ recordName: String) -> Bool { deleted.contains(recordName) }
    func delete(_ recordName: String) {
        let wasUploaded = entries.first { $0.reading.recordName == recordName }?.uploaded == true
        discard(recordName)
        if wasUploaded { queueDeletion(recordName) }
    }
    func queueDeletion(_ recordName: String) {
        if !pendingDeletions.contains(recordName) { pendingDeletions.append(recordName) }
    }
    func discard(_ recordName: String) {
        entries.removeAll { $0.reading.recordName == recordName }
        deleted.insert(recordName)
    }
    func markDeletionsDone(_ recordNames: [String]) {
        pendingDeletions.removeAll { recordNames.contains($0) }
    }
    func markUploaded(_ recordNames: [String]) {
        for index in entries.indices where recordNames.contains(entries[index].reading.recordName) {
            entries[index].uploaded = true
        }
    }
}

final class FakeHouseholdSync: HouseholdSync {
    var uploaded: [SyncReading] = []
    var deleted: [String] = []
    var changes: [SyncReading] = []
    var deletions: [String] = []
    var failing = false
    struct Offline: Error {}
    func upload(_ reading: SyncReading) async throws {
        if failing { throw Offline() }
        uploaded.append(reading)
    }
    func delete(recordName: String) async throws {
        if failing { throw Offline() }
        deleted.append(recordName)
    }
    func fetchChanges() async throws -> HouseholdChanges {
        if failing { throw Offline() }
        return HouseholdChanges(readings: changes, deletedRecordNames: deletions)
    }
}

/// The household's zone, shared by every phone's `PhoneSync`.
final class FakeHousehold {
    fileprivate(set) var records: Set<String> = []
    fileprivate var log: [(name: String, deleted: Bool)] = []
}

/// One phone's view of a `FakeHousehold`: it fetches the changes made since its previous fetch.
final class PhoneSync: HouseholdSync {
    private let household: FakeHousehold
    private var cursor = 0
    init(_ household: FakeHousehold) { self.household = household }
    func upload(_ reading: SyncReading) async throws {
        guard household.records.insert(reading.recordName).inserted else { return }
        household.log.append((reading.recordName, false))
    }
    func delete(recordName: String) async throws {
        guard household.records.remove(recordName) != nil else { return }
        household.log.append((recordName, true))
    }
    func fetchChanges() async throws -> HouseholdChanges {
        defer { cursor = household.log.count }
        let changes = household.log[cursor...]
        return HouseholdChanges(
            readings: changes.filter { !$0.deleted }.compactMap { Self.reading(named: $0.name) },
            deletedRecordNames: changes.filter(\.deleted).map(\.name))
    }
    private static func reading(named name: String) -> SyncReading? {
        let parts = name.split(separator: "-")
        guard parts.count == 4, let profile = Int(parts[1]), let seconds = Double(parts[2]), let tenths = Double(parts[3])
        else { return nil }
        return SyncReading(profile: profile, celsius: tenths / 10, measuredAt: Date(timeIntervalSince1970: seconds))
    }
}

private func reading(_ profile: Int?, _ celsius: Double = 36.4, at seconds: TimeInterval = 1_793_119_737)
    -> ThermometerReading
{
    ThermometerReading(profile: profile, celsius: celsius, measuredAt: Date(timeIntervalSince1970: seconds))
}

@Suite struct SyncReadingTests {
    @Test func recordNameIsDeterministic() {
        let a = SyncReading(reading(1))!
        #expect(a.recordName == "reading-1-1793119737-364")
        #expect(a.recordName == SyncReading(reading(1))!.recordName)
    }

    @Test func recordNameVariesWithEachComponent() {
        let base = SyncReading(reading(1))!.recordName
        #expect(SyncReading(reading(2))!.recordName != base)
        #expect(SyncReading(reading(1, 36.5))!.recordName != base)
        #expect(SyncReading(reading(1, at: 1_793_119_738))!.recordName != base)
    }

    @Test func subSecondTimeAndFloatNoiseDoNotChangeTheName() {
        #expect(
            SyncReading(reading(1, 36.4, at: 1_793_119_737.6))!.recordName
                == SyncReading(reading(1, 36.400000001))!.recordName)
    }

    @Test func ambiguousReadingHasNoSyncForm() {
        #expect(SyncReading(reading(nil)) == nil)
    }
}

@Suite struct FileReadingStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    }

    @Test func persistsAcrossInstancesIncludingUploadedState() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = SyncReading(reading(1))!
        let b = SyncReading(reading(2))!
        let store = FileReadingStore(url: url)
        #expect(store.add(a, uploaded: false))
        #expect(store.add(b, uploaded: false))
        store.markUploaded([a.recordName])

        let reloaded = FileReadingStore(url: url)
        #expect(reloaded.all == [a, b])
        #expect(reloaded.pending == [b])
    }

    @Test func addIgnoresDuplicates() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileReadingStore(url: url)
        let a = SyncReading(reading(1))!
        #expect(store.add(a, uploaded: false))
        #expect(!store.add(a, uploaded: true))
        #expect(store.pending == [a])
    }

    @Test func deletedReadingStaysDeletedAcrossInstances() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileReadingStore(url: url)
        let a = SyncReading(reading(1))!
        let b = SyncReading(reading(2))!
        store.add(a, uploaded: false)
        store.add(b, uploaded: true)
        store.delete(a.recordName)
        #expect(store.all == [b])
        #expect(store.pending.isEmpty)
        #expect(!store.add(a, uploaded: true))

        let reloaded = FileReadingStore(url: url)
        #expect(reloaded.all == [b])
        #expect(reloaded.isDeleted(a.recordName))
        #expect(!reloaded.add(a, uploaded: false))
    }

    @Test func queuesTheHouseholdDeletionOfAnUploadedReadingAcrossInstances() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileReadingStore(url: url)
        let a = SyncReading(reading(1))!
        let b = SyncReading(reading(2))!
        store.add(a, uploaded: true)
        store.add(b, uploaded: false)
        store.delete(a.recordName)
        store.delete(b.recordName)
        #expect(store.pendingDeletions == [a.recordName])

        let reloaded = FileReadingStore(url: url)
        #expect(reloaded.pendingDeletions == [a.recordName])
        reloaded.markDeletionsDone([a.recordName])
        #expect(FileReadingStore(url: url).pendingDeletions.isEmpty)
        #expect(FileReadingStore(url: url).isDeleted(a.recordName))
    }

    @Test func discardGuardsWithoutQueueingADeletion() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileReadingStore(url: url)
        let a = SyncReading(reading(1))!
        store.add(a, uploaded: true)
        store.discard(a.recordName)
        #expect(store.all.isEmpty)
        #expect(store.pendingDeletions.isEmpty)
        #expect(!store.add(a, uploaded: true))
    }

    @Test func readsASnapshotWithoutPendingDeletions() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"entries\":[],\"deleted\":[\"x\"]}".utf8).write(to: url)
        let store = FileReadingStore(url: url)
        #expect(store.isDeleted("x"))
        #expect(store.pendingDeletions.isEmpty)
    }

    @Test func readsAStoreWrittenAsABareEntryList() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = SyncReading(reading(1))!
        let legacy = "[{\"reading\":\(String(decoding: try JSONEncoder().encode(a), as: UTF8.self)),\"uploaded\":false}]"
        try Data(legacy.utf8).write(to: url)
        let store = FileReadingStore(url: url)
        #expect(store.all == [a])
        #expect(store.pending == [a])
    }
}

@MainActor
@Suite struct ReadingSyncCoordinatorTests {
    let store = InMemoryReadingStore()
    let remote = FakeHouseholdSync()
    var coordinator: ReadingSyncCoordinator { ReadingSyncCoordinator(store: store, sync: remote) }

    @Test func neverUploadsUnattributedReadings() async {
        let c = coordinator
        c.record(reading(nil))
        #expect(await c.flush())
        #expect(store.all.isEmpty)
        #expect(remote.uploaded.isEmpty)
    }

    @Test func neverUploadsUntrackedProfiles() async {
        let c = ReadingSyncCoordinator(store: store, sync: remote, isTracked: { $0 != 2 })
        c.record(reading(2))
        #expect(await c.flush())
        #expect(store.all.isEmpty)
        #expect(remote.uploaded.isEmpty)
    }

    @Test func persistsOnReceiptAndUploadsOnFlush() async {
        let c = coordinator
        c.record(reading(1))
        #expect(store.pending.count == 1)
        #expect(await c.flush())
        #expect(remote.uploaded == [SyncReading(reading(1))!])
        #expect(store.pending.isEmpty)
    }

    @Test func keepsReadingsInTheOutboxWhileOffline() async {
        let c = coordinator
        remote.failing = true
        c.record(reading(1))
        #expect(await c.flush() == false)
        #expect(store.pending.count == 1)

        remote.failing = false
        #expect(await c.flush())
        #expect(remote.uploaded.count == 1)
        #expect(store.pending.isEmpty)
    }

    @Test func deletedReadingIsNeverUploaded() async {
        let c = coordinator
        c.record(reading(1))
        c.delete(reading(1))
        #expect(await c.flush())
        #expect(remote.uploaded.isEmpty)
        #expect(c.storedReadings.isEmpty)
        #expect(c.isDeleted(reading(1)))
    }

    @Test func deletedReadingIsNotRecordedOrPulledAgain() async throws {
        let c = coordinator
        c.record(reading(1))
        c.delete(reading(1))
        c.record(reading(1))
        remote.changes = [SyncReading(reading(1))!]
        #expect(try await c.pull().added.isEmpty)
        #expect(store.all.isEmpty)
    }

    @Test func pullReturnsOnlyReadingsNotHeldLocally() async throws {
        let c = coordinator
        c.record(reading(1))
        remote.changes = [SyncReading(reading(1))!, SyncReading(reading(2, at: 1_793_119_800))!]
        let fetched = try await c.pull()
        #expect(fetched.added == [reading(2, at: 1_793_119_800)])
        #expect(try await c.pull().added.isEmpty)
        #expect(store.pending.count == 1)
    }
}

@MainActor
@Suite struct HouseholdDeletionTests {
    let store = InMemoryReadingStore()
    let remote = FakeHouseholdSync()
    var coordinator: ReadingSyncCoordinator { ReadingSyncCoordinator(store: store, sync: remote) }
    let name = SyncReading(reading(1))!.recordName

    @Test func deletingAnUploadedReadingDeletesTheHouseholdCopy() async {
        let c = coordinator
        c.record(reading(1))
        await c.flush()
        c.delete(reading(1))
        #expect(store.pendingDeletions == [name])

        #expect(await c.flush())
        #expect(remote.deleted == [name])
        #expect(store.pendingDeletions.isEmpty)
        #expect(c.isDeleted(reading(1)))
    }

    @Test func deletingAnUnuploadedReadingOnlyDropsItFromTheOutbox() async {
        let c = coordinator
        c.record(reading(1))
        c.delete(reading(1))
        #expect(store.pendingDeletions.isEmpty)
        #expect(await c.flush())
        #expect(remote.deleted.isEmpty)
        #expect(remote.uploaded.isEmpty)
    }

    @Test func deletionRetriesWhileOffline() async {
        let c = coordinator
        c.record(reading(1))
        await c.flush()
        c.delete(reading(1))
        remote.failing = true
        #expect(await c.flush() == false)
        #expect(store.pendingDeletions == [name])

        remote.failing = false
        #expect(await c.flush())
        #expect(remote.deleted == [name])
        #expect(store.pendingDeletions.isEmpty)
    }

    @Test func pulledDeletionRemovesTheReading() async throws {
        let c = coordinator
        c.record(reading(1))
        remote.deletions = [name]
        let pulled = try await c.pull()
        #expect(pulled.deletedRecordNames == [name])
        #expect(store.all.isEmpty)
        #expect(store.pending.isEmpty)
        #expect(store.pendingDeletions.isEmpty)
    }

    @Test func pulledDeletionGuardsAgainstRedelivery() async throws {
        let c = coordinator
        c.record(reading(1))
        remote.deletions = [name]
        _ = try await c.pull()
        c.record(reading(1))
        remote.deletions = []
        remote.changes = [SyncReading(reading(1))!]
        #expect(try await c.pull().added.isEmpty)
        #expect(store.all.isEmpty)
        #expect(await c.flush())
        #expect(remote.uploaded.isEmpty)
    }

    @Test func readingDeletedDuringItsUploadIsDeletedFromTheHousehold() async {
        let slow = SlowUploadSync()
        let c = ReadingSyncCoordinator(store: store, sync: slow)
        c.record(reading(1))
        let flushing = Task { await c.flush() }
        await slow.uploadStarted()
        c.delete(reading(1))
        slow.finishUpload()
        await flushing.value
        #expect(slow.deleted == [name])
        #expect(store.pendingDeletions.isEmpty)
    }

    @Test func deletionReachesAnotherPhoneOnItsNextPull() async throws {
        let household = FakeHousehold()
        let storeA = InMemoryReadingStore()
        let storeB = InMemoryReadingStore()
        let a = ReadingSyncCoordinator(store: storeA, sync: PhoneSync(household))
        let b = ReadingSyncCoordinator(store: storeB, sync: PhoneSync(household))
        a.record(reading(1))
        a.record(reading(2, at: 1_793_119_800))
        await a.flush()
        #expect(try await b.pull().added.count == 2)

        a.delete(reading(1))
        await a.flush()
        #expect(household.records == [SyncReading(reading(2, at: 1_793_119_800))!.recordName])

        let pulled = try await b.pull()
        #expect(pulled.deletedRecordNames == [name])
        #expect(storeB.all.map(\.recordName) == [SyncReading(reading(2, at: 1_793_119_800))!.recordName])
        #expect(try await a.pull().added.isEmpty)
    }

    @Test func deletingTwiceFromTwoPhonesSucceeds() async {
        let household = FakeHousehold()
        let a = ReadingSyncCoordinator(store: InMemoryReadingStore(), sync: PhoneSync(household))
        let b = ReadingSyncCoordinator(store: InMemoryReadingStore(), sync: PhoneSync(household))
        a.record(reading(1))
        await a.flush()
        _ = try? await b.pull()
        a.delete(reading(1))
        b.delete(reading(1))
        #expect(await a.flush())
        #expect(await b.flush())
        #expect(household.records.isEmpty)
    }
}

/// Holds an upload open until released, to delete a reading while its upload is in flight.
@MainActor
final class SlowUploadSync: HouseholdSync {
    var deleted: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var shouldFinish = false

    func uploadStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishUpload() {
        shouldFinish = true
        finish?.resume()
        finish = nil
    }
    func upload(_ reading: SyncReading) async throws {
        hasStarted = true
        started?.resume()
        started = nil
        if !shouldFinish { await withCheckedContinuation { finish = $0 } }
    }
    func delete(recordName: String) async throws { deleted.append(recordName) }
    func fetchChanges() async throws -> HouseholdChanges { HouseholdChanges() }
}

@Suite struct CloudKitMappingTests {
    @Test func recordRoundTrips() {
        let zoneID = CKRecordZone.ID(zoneName: CloudKitHouseholdSync.zoneName)
        let source = SyncReading(reading(2, 35.9))!
        let record = CloudKitHouseholdSync.record(for: source, in: zoneID)
        #expect(record.recordID.recordName == source.recordName)
        #expect(record.recordID.zoneID == zoneID)
        #expect(CloudKitHouseholdSync.reading(from: record) == source)
    }

    @Test func foreignRecordTypeIsIgnored() {
        #expect(CloudKitHouseholdSync.reading(from: CKRecord(recordType: "Other")) == nil)
    }

    @Test func unknownItemCountsAsAlreadyDeleted() {
        #expect(CloudKitHouseholdSync.isAlreadyDeleted(CKError(.unknownItem)))
        #expect(!CloudKitHouseholdSync.isAlreadyDeleted(CKError(.networkUnavailable)))
    }

    @Test func serverRecordChangedCountsAsDuplicate() {
        #expect(CloudKitHouseholdSync.isDuplicate(CKError(.serverRecordChanged)))
        #expect(!CloudKitHouseholdSync.isDuplicate(CKError(.networkUnavailable)))
    }
}
