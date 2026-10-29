import CloudKit
import Foundation
import Testing

@testable import Kintemp

/// The household's profile records as the server holds them; each phone syncs through its own `Phone`.
final class FakeProfileCloud {
    private(set) var records: [Int: (name: String, isIgnored: Bool, modifiedAt: Date)] = [:]
    fileprivate var log: [ProfileChange] = []
    /// When set, saves fail like Production does while its schema lacks `Profile`.
    var failure: Error?
    private var clock = Date.distantPast

    func phone() -> Phone { Phone(cloud: self) }

    func delete(slot: Int) {
        records[slot] = nil
        log.append(.reset(slot: slot))
    }

    fileprivate func save(_ profile: Profile) throws -> ProfileChange {
        if let failure { throw failure }
        if let existing = records[profile.slot], existing.modifiedAt >= profile.modifiedAt ?? .distantPast {
            return .upsert(
                slot: profile.slot, name: existing.name, isIgnored: existing.isIgnored, modifiedAt: existing.modifiedAt)
        }
        clock = max(Date.now, clock.addingTimeInterval(0.001))
        records[profile.slot] = (profile.name, profile.isIgnored, clock)
        let change = ProfileChange.upsert(
            slot: profile.slot, name: profile.name, isIgnored: profile.isIgnored, modifiedAt: clock)
        log.append(change)
        return change
    }

    final class Phone: ProfileSync {
        private let cloud: FakeProfileCloud
        private var cursor = 0
        fileprivate init(cloud: FakeProfileCloud) { self.cloud = cloud }

        func uploadProfile(_ profile: Profile) async throws -> ProfileChange { try cloud.save(profile) }

        func takeProfileChanges() -> [ProfileChange] {
            defer { cursor = cloud.log.count }
            return Array(cloud.log[cursor...])
        }
    }
}

private final class MemoryStore: ProfileStore {
    var profiles: [Profile] = []
    func load() -> [Profile] { profiles }
    func save(_ profiles: [Profile]) { self.profiles = profiles }
}

@MainActor
private struct PhoneRig {
    let book: ProfileBook
    let coordinator: ProfileSyncCoordinator
    var logged: LogBox

    final class LogBox { var lines: [String] = [] }

    init(cloud: FakeProfileCloud) {
        let box = LogBox()
        let book = ProfileBook(store: MemoryStore())
        self.book = book
        logged = box
        coordinator = ProfileSyncCoordinator(book: book, sync: cloud.phone(), log: { box.lines.append($0) })
        book.onChange = nil  // tests flush explicitly
    }
}

@MainActor
@Suite struct ProfileSyncTests {
    let cloud = FakeProfileCloud()

    @Test func renameOnOnePhoneAppearsOnTheOther() async {
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 1, to: "Alex")
        a.book.setIgnored(slot: 2, true)
        #expect(await a.coordinator.flush())

        #expect(b.coordinator.pull())
        #expect(b.book.displayName(slot: 1) == "Alex")
        #expect(b.book.profile(slot: 2).isIgnored)
        #expect(b.book.pendingUploads.isEmpty)
        #expect(a.book.pendingUploads.isEmpty)
    }

    @Test func laterRenameOverwritesOnEveryPhone() async throws {
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 1, to: "Alex")
        await a.coordinator.flush()
        b.coordinator.pull()

        try await Task.sleep(for: .milliseconds(5))
        b.book.rename(slot: 1, to: "Sam")
        await b.coordinator.flush()

        #expect(a.coordinator.pull())
        #expect(a.book.displayName(slot: 1) == "Sam")
        #expect(cloud.records[1]?.name == "Sam")
    }

    @Test func newerEditWinsWhicheverPhoneUploadsFirst() async throws {
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 1, to: "Older")
        try await Task.sleep(for: .milliseconds(5))
        b.book.rename(slot: 1, to: "Newer")

        await b.coordinator.flush()
        await a.coordinator.flush()
        b.coordinator.pull()

        #expect(a.book.displayName(slot: 1) == "Newer")
        #expect(b.book.displayName(slot: 1) == "Newer")
        #expect(cloud.records[1]?.name == "Newer")
    }

    @Test func offlineEditsStayPendingAndUploadLater() async {
        let a = PhoneRig(cloud: cloud)
        cloud.failure = CKError(.networkUnavailable)
        a.book.rename(slot: 1, to: "Alex")
        #expect(await a.coordinator.flush() == false)
        #expect(a.book.displayName(slot: 1) == "Alex")
        #expect(a.book.pendingUploads.map(\.slot) == [1])

        cloud.failure = nil
        #expect(await a.coordinator.flush())
        #expect(a.book.pendingUploads.isEmpty)
        #expect(cloud.records[1]?.name == "Alex")
    }

    @Test func missingProductionSchemaKeepsNamesLocalAndLogsInsteadOfFailing() async {
        let a = PhoneRig(cloud: cloud)
        cloud.failure = CKError(.serverRejectedRequest)
        a.book.rename(slot: 2, to: "Sam")

        #expect(await a.coordinator.flush() == false)
        #expect(a.book.displayName(slot: 2) == "Sam")
        #expect(a.logged.lines.count == 1)
        #expect(a.logged.lines[0].contains("profile 2"))

        cloud.failure = nil
        #expect(await a.coordinator.flush())
        #expect(cloud.records[2]?.name == "Sam")
    }

    @Test func deletedRecordResetsTheProfileToDefaults() async {
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 1, to: "Alex")
        a.book.setIgnored(slot: 1, true)
        await a.coordinator.flush()
        b.coordinator.pull()

        cloud.delete(slot: 1)

        #expect(b.coordinator.pull())
        #expect(b.book.profile(slot: 1).name == "Profile 1")
        #expect(!b.book.profile(slot: 1).isIgnored)
    }

    @Test func deletedRecordDoesNotDiscardAPendingEdit() async {
        let a = PhoneRig(cloud: cloud)
        cloud.failure = CKError(.networkUnavailable)
        a.book.rename(slot: 1, to: "Alex")
        await a.coordinator.flush()
        cloud.delete(slot: 1)
        a.coordinator.pull()

        #expect(a.book.displayName(slot: 1) == "Alex")
        cloud.failure = nil
        await a.coordinator.flush()
        #expect(cloud.records[1]?.name == "Alex")
    }

    @Test func guestSlotStaysUntracked() async {
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 0, to: "Visitor")
        await a.coordinator.flush()
        b.coordinator.pull()
        #expect(b.book.displayName(slot: 0) == "Visitor")
        #expect(!b.book.profile(slot: 0).isTracked)
    }

    @Test func myProfileSelectionStaysLocal() async {
        struct StubWriter: HealthWriter {
            func writeStatus() -> HealthWriteStatus { .authorized }
            func requestAuthorization() async throws {}
            func write(_ sample: HealthSample) async throws {}
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let health = HealthSync(writer: StubWriter(), defaults: defaults)
        health.myProfile = 1
        let a = PhoneRig(cloud: cloud)
        let b = PhoneRig(cloud: cloud)
        a.book.rename(slot: 2, to: "Sam")
        await a.coordinator.flush()
        b.coordinator.pull()

        #expect(health.myProfile == 1)
        #expect(b.book.profile(slot: 2).owner == nil)
        #expect(cloud.records.keys.sorted() == [2])
    }

    @Test func unchangedRenameUploadsNothing() async {
        let a = PhoneRig(cloud: cloud)
        a.book.rename(slot: 1, to: "Profile 1")
        a.book.rename(slot: 1, to: "  ")
        #expect(a.book.pendingUploads.isEmpty)
        #expect(cloud.records.isEmpty)
    }
}

struct ProfileMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func newerHouseholdVersionReplacesAnOlderLocalEdit() {
        var directory = ProfileDirectory(store: MemoryStore())
        directory.rename(slot: 1, to: "Local", at: t0)
        let changed = directory.apply(
            .upsert(slot: 1, name: "Remote", isIgnored: false, modifiedAt: t0.addingTimeInterval(1)))
        #expect(changed)
        #expect(directory.profile(slot: 1).name == "Remote")
        #expect(directory.pendingUploads.isEmpty)
    }

    @Test func olderHouseholdVersionKeepsTheNewerLocalEdit() {
        var directory = ProfileDirectory(store: MemoryStore())
        directory.rename(slot: 1, to: "Local", at: t0)
        let changed = directory.apply(
            .upsert(slot: 1, name: "Remote", isIgnored: false, modifiedAt: t0.addingTimeInterval(-1)))
        #expect(!changed)
        #expect(directory.profile(slot: 1).name == "Local")
        #expect(directory.pendingUploads.map(\.slot) == [1])
    }

    @Test func householdChangeKeepsTheLocalOwner() {
        var directory = ProfileDirectory(store: MemoryStore())
        directory.setOwner(slot: 1, "me")
        directory.apply(.upsert(slot: 1, name: "Alex", isIgnored: false, modifiedAt: t0))
        #expect(directory.profile(slot: 1).owner == "me")
    }

    @Test func editDuringUploadStaysPending() {
        var directory = ProfileDirectory(store: MemoryStore())
        directory.rename(slot: 1, to: "First", at: t0)
        let uploading = directory.profile(slot: 1)
        directory.rename(slot: 1, to: "Second", at: t0.addingTimeInterval(1))
        directory.finishUpload(
            of: uploading,
            result: .upsert(slot: 1, name: "First", isIgnored: false, modifiedAt: t0.addingTimeInterval(2)))
        #expect(directory.profile(slot: 1).name == "Second")
        #expect(directory.pendingUploads.map(\.slot) == [1])
    }

    @Test func profilesNamedBeforeSyncingAreQueuedForUpload() throws {
        let legacy = Data(#"[{"slot":1,"name":"Alex","isIgnored":false},{"slot":2,"name":"Profile 2"}]"#.utf8)
        let store = MemoryStore()
        store.profiles = try JSONDecoder().decode([Profile].self, from: legacy)
        #expect(ProfileDirectory(store: store).pendingUploads.map(\.slot) == [1])
    }
}

@MainActor
@Suite struct ProfileSyncModelTests {
    private struct StubWriter: HealthWriter {
        func writeStatus() -> HealthWriteStatus { .authorized }
        func requestAuthorization() async throws {}
        func write(_ sample: HealthSample) async throws {}
    }

    private final class StubClient: ThermometerClient {
        let events = AsyncStream<ThermometerEvent> { _ in }
        func start() {}
    }

    @Test func syncReportsNewDataWhenOnlyProfilesChanged() async {
        let cloud = FakeProfileCloud()
        let other = PhoneRig(cloud: cloud)
        other.book.rename(slot: 1, to: "Alex")
        await other.coordinator.flush()

        let book = ProfileBook(store: MemoryStore())
        let model = ReadingsModel(
            client: StubClient(),
            sync: ReadingSyncCoordinator(store: InMemoryReadingStore(), sync: FakeHouseholdSync()),
            health: HealthSync(writer: StubWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!))
        model.profileSync = ProfileSyncCoordinator(book: book, sync: cloud.phone(), log: { _ in })

        #expect(await model.syncHousehold() == .newData)
        #expect(book.displayName(slot: 1) == "Alex")
        #expect(await model.syncHousehold() == .noData)
    }
}

struct ProfileCloudKitMappingTests {
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitHouseholdSync.zoneName)

    @Test func recordUsesADeterministicNamePerSlot() {
        let record = CloudKitHouseholdSync.profileRecord(
            for: Profile(slot: 2, name: "Sam", isIgnored: true), in: zoneID)
        #expect(record.recordType == "Profile")
        #expect(record.recordID == CKRecord.ID(recordName: "profile-2", zoneID: zoneID))
        #expect(record["slot"] as? Int == 2)
        #expect(record["name"] as? String == "Sam")
        #expect(record["ignored"] as? Int == 1)
    }

    @Test func slotParsesFromTheRecordName() {
        #expect(CloudKitHouseholdSync.profileSlot(recordName: "profile-1") == 1)
        #expect(CloudKitHouseholdSync.profileSlot(recordName: "reading-1-2-3") == nil)
    }

    @Test func foreignOrIncompleteRecordsAreIgnored() {
        #expect(CloudKitHouseholdSync.profileChange(from: CKRecord(recordType: "Reading")) == nil)
        #expect(CloudKitHouseholdSync.profileChange(from: CKRecord(recordType: "Profile")) == nil)
    }
}
