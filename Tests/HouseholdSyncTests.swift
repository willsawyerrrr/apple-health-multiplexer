import CloudKit
import Foundation
import Testing

@testable import Kintemp

final class InMemoryReadingStore: ReadingStore {
    private var entries: [(reading: SyncReading, uploaded: Bool)] = []
    var all: [SyncReading] { entries.map(\.reading) }
    var pending: [SyncReading] {
        entries.filter { !$0.uploaded }.map(\.reading).sorted { $0.measuredAt < $1.measuredAt }
    }
    func add(_ reading: SyncReading, uploaded: Bool) -> Bool {
        guard !entries.contains(where: { $0.reading == reading }) else { return false }
        entries.append((reading, uploaded))
        return true
    }
    func markUploaded(_ recordNames: [String]) {
        for index in entries.indices where recordNames.contains(entries[index].reading.recordName) {
            entries[index].uploaded = true
        }
    }
}

final class FakeHouseholdSync: HouseholdSync {
    var uploaded: [SyncReading] = []
    var changes: [SyncReading] = []
    var failing = false
    struct Offline: Error {}
    func upload(_ reading: SyncReading) async throws {
        if failing { throw Offline() }
        uploaded.append(reading)
    }
    func fetchChanges() async throws -> [SyncReading] {
        if failing { throw Offline() }
        return changes
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

    @Test func pullReturnsOnlyReadingsNotHeldLocally() async throws {
        let c = coordinator
        c.record(reading(1))
        remote.changes = [SyncReading(reading(1))!, SyncReading(reading(2, at: 1_793_119_800))!]
        let fetched = try await c.pull()
        #expect(fetched == [reading(2, at: 1_793_119_800)])
        #expect(try await c.pull().isEmpty)
        #expect(store.pending.count == 1)
    }
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

    @Test func serverRecordChangedCountsAsDuplicate() {
        #expect(CloudKitHouseholdSync.isDuplicate(CKError(.serverRecordChanged)))
        #expect(!CloudKitHouseholdSync.isDuplicate(CKError(.networkUnavailable)))
    }
}
