import Foundation
import Testing

@testable import Kintemp

private final class FakeWriter: HealthWriter, @unchecked Sendable {
    var written: [HealthSample] = []
    var failing = true
    struct Locked: Error {}
    func requestAuthorization() async throws {}
    func write(_ sample: HealthSample) async throws {
        if failing { throw Locked() }
        written.append(sample)
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
}
