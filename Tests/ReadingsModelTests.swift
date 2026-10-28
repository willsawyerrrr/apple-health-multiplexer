import Foundation
import Testing

@testable import Kintemp

@MainActor
struct ReadingsModelTests {
    private final class StubClient: ThermometerClient {
        let events = AsyncStream<ThermometerEvent> { _ in }
        func start() {}
    }

    private struct StubWriter: HealthWriter {
        func writeStatus() -> HealthWriteStatus { .authorized }
        func requestAuthorization() async throws {}
        func write(_ sample: HealthSample) async throws { throw CancellationError() }
    }

    private final class StubSync: HouseholdSync {
        var changes: [SyncReading] = []
        func upload(_ reading: SyncReading) async throws {}
        func fetchChanges() async throws -> [SyncReading] { changes }
    }

    private func makeModel(myProfile: Int? = nil, sync: ReadingSyncCoordinator? = nil) -> ReadingsModel {
        let health = HealthSync(writer: StubWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        health.myProfile = myProfile
        return ReadingsModel(client: StubClient(), sync: sync, health: health)
    }

    private func makeCoordinator(
        store: ReadingStore = InMemoryReadingStore(), remote: StubSync = StubSync()
    ) -> ReadingSyncCoordinator {
        ReadingSyncCoordinator(store: store, sync: remote)
    }

    private func reading(_ celsius: Double, at seconds: TimeInterval) -> ThermometerReading {
        ThermometerReading(profile: 1, celsius: celsius, measuredAt: Date(timeIntervalSince1970: seconds))
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
}
