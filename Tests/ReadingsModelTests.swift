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
        func requestAuthorization() async throws {}
        func write(_ sample: HealthSample) async throws { throw CancellationError() }
    }

    private func makeModel(myProfile: Int? = nil) -> ReadingsModel {
        let health = HealthSync(writer: StubWriter(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        health.myProfile = myProfile
        return ReadingsModel(client: StubClient(), health: health)
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

    @Test func readingsForMyProfileAreQueuedForHealth() {
        let model = makeModel(myProfile: 1)
        let mine = reading(36.1, at: 100)
        let other = ThermometerReading(profile: 2, celsius: 36.5, measuredAt: Date(timeIntervalSince1970: 200))
        model.handle(.reading(mine))
        model.handle(.reading(other))

        #expect(model.health.pending.map(\.celsius) == [36.1])
    }
}
