import Foundation
import Testing

@testable import Kintemp

private final class FakeWriter: HealthWriter, @unchecked Sendable {
    var written: [HealthSample] = []
    var deleted: [String] = []
    var failingDeletes = false
    var failing = true
    var status = HealthWriteStatus.notDetermined
    var grants = true
    var requests = 0
    struct Locked: Error {}
    func writeStatus() -> HealthWriteStatus { status }
    func requestAuthorization() async throws {
        requests += 1
        status = grants ? .authorized : .denied
    }
    func write(_ sample: HealthSample) async throws {
        if failing { throw Locked() }
        written.append(sample)
    }
    func delete(name: String) async throws {
        if failingDeletes { throw Locked() }
        deleted.append(name)
    }
}

@MainActor
private func makeSync(_ writer: FakeWriter, profile: Int? = 1) -> (HealthSync, UserDefaults) {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let sync = HealthSync(writer: writer, defaults: defaults)
    sync.myProfile = profile
    return (sync, defaults)
}

private func reading(_ profile: Int?, _ celsius: Double = 36.4, at ts: TimeInterval = 1_793_119_737) -> ThermometerReading {
    ThermometerReading(profile: profile, celsius: celsius, measuredAt: Date(timeIntervalSince1970: ts))
}

@MainActor @Suite struct HealthSyncTests {
    @Test func backfillsStoredReadingsWhenProfileIsSet() {
        let (sync, _) = makeSync(FakeWriter(), profile: nil)
        sync.storedReadings = { [reading(1, at: 1_793_119_737), reading(2, at: 1_793_119_800), reading(nil)] }
        sync.myProfile = 1
        #expect(sync.pending.map(\.name) == ["reading-1-1793119737-364"])
    }

    @Test func backfillsOnChangeToAnotherProfile() {
        let (sync, _) = makeSync(FakeWriter(), profile: nil)
        sync.storedReadings = { [reading(1, at: 1_793_119_737), reading(2, at: 1_793_119_800)] }
        sync.myProfile = 1
        sync.myProfile = 2
        #expect(sync.pending.map(\.name) == ["reading-1-1793119737-364", "reading-2-1793119800-364"])
    }

    @Test func backfillDoesNotRequeueQueuedReadings() {
        let (sync, _) = makeSync(FakeWriter(), profile: nil)
        sync.storedReadings = { [reading(1)] }
        sync.myProfile = 1
        sync.backfill()
        #expect(sync.pending.count == 1)
    }

    @Test func writtenReadingIsNotRequeuedAfterRelaunch() async {
        let writer = FakeWriter()
        writer.failing = false
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = HealthSync(writer: writer, defaults: defaults)
        first.myProfile = 1
        first.submit(reading(1))
        await first.flush()
        #expect(writer.written.count == 1)

        let relaunched = HealthSync(writer: writer, defaults: defaults)
        relaunched.storedReadings = { [reading(1)] }
        relaunched.backfill()
        relaunched.submit(reading(1))
        #expect(relaunched.pending.isEmpty)
    }

    @Test func removeForgetsWrittenReading() async {
        let writer = FakeWriter()
        writer.failing = false
        let (sync, _) = makeSync(writer)
        sync.submit(reading(1))
        await sync.flush()
        sync.remove(recordNames: [SyncReading(reading(1))!.recordName])
        #expect(sync.written.isEmpty)
        sync.submit(reading(1))
        #expect(sync.pending.count == 1)
    }

    @Test func backfillNeverQueuesGuestProfile() {
        let sync = HealthSync(
            writer: FakeWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!, isTracked: { $0 != 0 })
        sync.storedReadings = { [reading(0)] }
        sync.myProfile = 0
        #expect(sync.pending.isEmpty)
    }

    @Test func backfillSkipsUntrackedProfile() {
        let sync = HealthSync(
            writer: FakeWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!, isTracked: { $0 != 1 })
        sync.storedReadings = { [reading(1)] }
        sync.myProfile = 1
        #expect(sync.pending.isEmpty)
    }

    @Test func queuesOnlyMyProfile() {
        let (sync, _) = makeSync(FakeWriter(), profile: 1)
        sync.submit(reading(0))
        sync.submit(reading(nil))
        sync.submit(reading(1))
        #expect(sync.pending.map(\.name) == ["reading-1-1793119737-364"])
    }

    @Test func queuesNothingForUntrackedProfile() {
        let sync = HealthSync(
            writer: FakeWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!, isTracked: { $0 != 1 })
        sync.myProfile = 1
        sync.submit(reading(1))
        #expect(sync.pending.isEmpty)
    }

    @Test func namesAReadingSeenViaBluetoothAndCloudKitIdentically() {
        let (sync, _) = makeSync(FakeWriter(), profile: 1)
        let bluetooth = reading(1, 36.4, at: 1_793_119_737.4)
        let cloudKit = SyncReading(reading(1, 36.4, at: 1_793_119_737.9))!.reading
        sync.submit(bluetooth)
        sync.submit(cloudKit)
        #expect(sync.pending.count == 1)
    }

    @Test func queuesNothingWithoutProfile() {
        let (sync, _) = makeSync(FakeWriter(), profile: nil)
        sync.submit(reading(1))
        #expect(sync.pending.isEmpty)
    }

    @Test func dedupesByName() {
        let (sync, _) = makeSync(FakeWriter())
        sync.submit(reading(1))
        sync.submit(reading(1))
        #expect(sync.pending.count == 1)
    }

    @Test func failedWritesStayQueuedAndRetry() async {
        let writer = FakeWriter()
        let (sync, _) = makeSync(writer)
        sync.submit(reading(1))
        await sync.flush()
        #expect(sync.pending.count == 1)
        writer.failing = false
        await sync.flush()
        #expect(sync.pending.isEmpty)
        #expect(writer.written.map(\.celsius) == [36.4])
    }

    @Test func pendingSurvivesRelaunch() {
        let (sync, defaults) = makeSync(FakeWriter())
        sync.submit(reading(1))
        let relaunched = HealthSync(writer: FakeWriter(), defaults: defaults)
        #expect(relaunched.myProfile == 1)
        #expect(relaunched.pending == sync.pending)
    }

    @Test func requestsAccessWhenProfileIsSet() async {
        let writer = FakeWriter()
        let (sync, _) = makeSync(writer, profile: nil)
        await sync.requestAccess()
        #expect(writer.requests == 0)
        sync.myProfile = 2
        await sync.requestAccess()
        #expect(writer.requests == 1)
        #expect(sync.accessProblem == nil)
    }

    @Test func requestsAccessOnLaunchWhenProfileAlreadySet() async {
        let writer = FakeWriter()
        let (_, defaults) = makeSync(FakeWriter())
        let relaunched = HealthSync(writer: writer, defaults: defaults)
        await relaunched.requestAccess()
        #expect(writer.requests == 1)
    }

    @Test func doesNotRequestAccessAgainOnceDetermined() async {
        let writer = FakeWriter()
        let (sync, _) = makeSync(writer)
        await sync.requestAccess()
        sync.myProfile = 0
        await sync.requestAccess()
        sync.submit(reading(0))
        await sync.flush()
        #expect(writer.requests == 1)
    }

    @Test func reportsDeniedAccess() async {
        let writer = FakeWriter()
        writer.grants = false
        let (sync, _) = makeSync(writer)
        await sync.requestAccess()
        #expect(sync.accessProblem?.contains("Settings > Health") == true)
        writer.status = .authorized
        await sync.requestAccess()
        #expect(sync.accessProblem == nil)
    }

    @Test func removeDropsAnUnwrittenSample() {
        let (sync, _) = makeSync(FakeWriter())
        sync.submit(reading(1))
        sync.remove(recordNames: ["reading-1-1793119737-364"])
        #expect(sync.pending.isEmpty)
    }

    @Test func removeDeletesTheWrittenSample() async {
        let writer = FakeWriter()
        writer.failing = false
        let (sync, _) = makeSync(writer)
        sync.submit(reading(1))
        await sync.flush()
        #expect(writer.written.count == 1)

        sync.remove(recordNames: ["reading-1-1793119737-364"])
        await sync.flush()

        #expect(writer.deleted == ["reading-1-1793119737-364"])
        #expect(sync.pendingDeletions.isEmpty)
    }

    @Test func failedDeletionsStayQueuedAcrossRelaunchAndRetry() async {
        let writer = FakeWriter()
        writer.failingDeletes = true
        let (sync, defaults) = makeSync(writer)
        await sync.requestAccess()
        sync.remove(recordNames: ["reading-1-1793119737-364"])
        await sync.flush()
        #expect(sync.pendingDeletions == ["reading-1-1793119737-364"])

        writer.failingDeletes = false
        let relaunched = HealthSync(writer: writer, defaults: defaults)
        #expect(relaunched.pendingDeletions == ["reading-1-1793119737-364"])
        await relaunched.flush()
        #expect(writer.deleted == ["reading-1-1793119737-364"])
        #expect(relaunched.pendingDeletions.isEmpty)
    }

    @Test func deletionsAreSkippedQuietlyWhenAccessIsDenied() async {
        let writer = FakeWriter()
        writer.grants = false
        let (sync, _) = makeSync(writer)
        sync.remove(recordNames: ["reading-1-1793119737-364"])
        await sync.flush()
        #expect(writer.deleted.isEmpty)
        #expect(sync.pendingDeletions.isEmpty)
    }
}
