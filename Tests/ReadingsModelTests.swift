import Foundation
import Testing

@testable import Kintemp

@MainActor
struct ReadingsModelTests {
    private final class StubClient: ThermometerClient {
        let events = AsyncStream<ThermometerEvent> { _ in }
        func start() {}
        var edits: [Int: Bool] = [:]
        func setSlot(_ slot: Int, enabled: Bool) { edits[slot] = enabled }
    }

    private struct StubWriter: HealthWriter {
        func writeStatus() -> HealthWriteStatus { .authorized }
        func requestAuthorization() async throws {}
        func write(_ sample: HealthSample) async throws { throw CancellationError() }
        func delete(name: String) async throws { throw CancellationError() }
    }

    private final class StubSync: HouseholdSync {
        var changes: [SyncReading] = []
        var deletions: [String] = []
        func upload(_ reading: SyncReading) async throws {}
        func delete(recordName: String) async throws {}
        func fetchChanges() async throws -> HouseholdChanges { HouseholdChanges(readings: changes, deletedRecordNames: deletions) }
    }

    private func makeModel(
        myProfile: Int? = nil, sync: ReadingSyncCoordinator? = nil, client: ThermometerClient = StubClient()
    ) -> ReadingsModel {
        let health = HealthSync(writer: StubWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        health.myProfile = myProfile
        return ReadingsModel(client: client, sync: sync, health: health)
    }

    private func makeCoordinator(
        store: ReadingStore = InMemoryReadingStore(), remote: StubSync = StubSync()
    ) -> ReadingSyncCoordinator {
        ReadingSyncCoordinator(store: store, sync: remote)
    }

    private func reading(_ celsius: Double, at seconds: TimeInterval) -> ThermometerReading {
        ThermometerReading(profile: 1, celsius: celsius, measuredAt: Date(timeIntervalSince1970: seconds))
    }

    private let firstParty = EnabledSlotMask(Data(hex: "E0FF 0000 0000 0000 0000 0000 0000"))!

    @Test func slotsAreUnknownBeforeTheMaskIsRead() {
        let model = makeModel()
        #expect(model.visibleSlots == nil)
        #expect(model.slotForNewPerson(reserved: []) == nil)
    }

    @Test func addedAndRemovedSlotsShowBeforeTheyReachTheThermometer() {
        let client = StubClient()
        let model = makeModel(client: client)
        model.handle(.enabledSlots(firstParty, pending: [:]))

        model.addSlot(11)
        model.removeSlot(3)

        #expect(client.edits == [11: true, 3: false])
        #expect(model.visibleSlots == [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    @Test func newPersonTakesTheLowestSlotNotEnabledReservedOrRead() {
        let model = makeModel()
        model.handle(.enabledSlots(firstParty, pending: [:]))
        model.handle(.reading(ThermometerReading(profile: 11, celsius: 36.5, measuredAt: Date(timeIntervalSince1970: 1))))

        #expect(model.slotForNewPerson(reserved: [12]) == 13)
    }

    @Test func deleteRemovesOnlyThatReading() {
        let model = makeModel()
        let a = reading(36.1, at: 100)
        let b = reading(36.5, at: 200)
        model.handle(.reading(a))
        model.handle(.reading(b))

        model.delete(a)

        #expect(model.readings == [b])
    }

    @Test func deleteOfUnknownReadingIsNoOp() {
        let model = makeModel()
        let a = reading(36.1, at: 100)
        model.handle(.reading(a))

        model.delete(reading(37.0, at: 300))

        #expect(model.readings == [a])
    }

    @Test func deletedReadingIsNotReAddedByBluetooth() {
        let model = makeModel(myProfile: 1, sync: makeCoordinator())
        let a = reading(36.1, at: 100)
        model.handle(.reading(a))
        model.delete(a)
        model.handle(.reading(a))

        #expect(model.readings.isEmpty)
        #expect(model.health.pending.isEmpty)
    }

    @Test func deletedReadingIsNotReAddedByPull() async {
        let remote = StubSync()
        let model = makeModel(sync: makeCoordinator(remote: remote))
        let a = reading(36.1, at: 100)
        model.handle(.reading(a))
        model.delete(a)
        remote.changes = [SyncReading(a)!]
        await model.syncHousehold()

        #expect(model.readings.isEmpty)
    }

    @Test func syncHouseholdReportsWhatThePullFound() async {
        let remote = StubSync()
        let model = makeModel(sync: makeCoordinator(remote: remote))
        #expect(await model.syncHousehold() == .noData)

        remote.changes = [SyncReading(reading(36.1, at: 100))!]
        #expect(await model.syncHousehold() == .newData)
        #expect(model.readings.count == 1)
        #expect(await model.syncHousehold() == .noData)
    }

    @Test func syncHouseholdReportsFailure() async {
        let remote = FakeHouseholdSync()
        remote.failing = true
        let model = makeModel(sync: ReadingSyncCoordinator(store: InMemoryReadingStore(), sync: remote))
        #expect(await model.syncHousehold() == .failed)
    }

    @Test func deletedReadingStaysDeletedAfterRelaunch() {
        let store = InMemoryReadingStore()
        let first = makeModel(sync: makeCoordinator(store: store))
        let a = reading(36.1, at: 100)
        first.handle(.reading(a))
        first.delete(a)

        let relaunched = makeModel(sync: makeCoordinator(store: store))
        relaunched.handle(.reading(a))

        #expect(relaunched.readings.isEmpty)
    }

    @Test func backfillsStoredReadingsOnLaunchButNotDeletedOnes() {
        let store = InMemoryReadingStore()
        let first = makeModel(sync: makeCoordinator(store: store))
        let kept = reading(36.1, at: 100)
        let deleted = reading(36.5, at: 200)
        first.handle(.reading(kept))
        first.handle(.reading(deleted))
        first.delete(deleted)

        let relaunched = makeModel(myProfile: 1, sync: makeCoordinator(store: store))

        #expect(relaunched.health.pending.map(\.name) == [SyncReading(kept)!.recordName])
    }

    @Test func backfillsReadingsReceivedBeforeProfileWasSet() {
        let model = makeModel()
        model.handle(.reading(reading(36.1, at: 100)))
        model.health.myProfile = 1

        #expect(model.health.pending.count == 1)
    }

    @Test func deleteDropsUnwrittenHealthSample() {
        let model = makeModel(myProfile: 1)
        let a = reading(36.1, at: 100)
        model.handle(.reading(a))
        #expect(model.health.pending.count == 1)

        model.delete(a)

        #expect(model.health.pending.isEmpty)
    }

    @Test func readingsForMyProfileAreQueuedForHealth() {
        let model = makeModel(myProfile: 1)
        let mine = reading(36.1, at: 100)
        let other = ThermometerReading(profile: 2, celsius: 36.5, measuredAt: Date(timeIntervalSince1970: 200))
        model.handle(.reading(mine))
        model.handle(.reading(other))

        #expect(model.health.pending.map(\.celsius) == [36.1])
    }

    @Test func deleteQueuesHouseholdAndHealthDeletion() async {
        let store = InMemoryReadingStore()
        let model = makeModel(myProfile: 1, sync: makeCoordinator(store: store))
        let a = reading(36.1, at: 100)
        store.add(SyncReading(a)!, uploaded: true)
        model.handle(.reading(a))

        model.delete(a)

        #expect(model.readings.isEmpty)
        #expect(store.pendingDeletions == [SyncReading(a)!.recordName])
        #expect(model.health.pendingDeletions == [SyncReading(a)!.recordName])
    }

    @Test func pulledHouseholdDeletionRemovesTheReadingAndItsHealthSample() async {
        let remote = StubSync()
        let model = makeModel(myProfile: 1, sync: makeCoordinator(remote: remote))
        let a = reading(36.1, at: 100)
        let b = reading(36.5, at: 200)
        model.handle(.reading(a))
        model.handle(.reading(b))
        remote.deletions = [SyncReading(a)!.recordName]

        await model.syncHousehold()

        #expect(model.readings == [b])
        #expect(model.health.pending.map(\.name) == [SyncReading(b)!.recordName])
        #expect(model.health.pendingDeletions == [SyncReading(a)!.recordName])
    }
}
