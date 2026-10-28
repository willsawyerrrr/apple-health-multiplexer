import Foundation
import Testing

@testable import Kintemp

@MainActor
struct ReadingsModelTests {
    private final class StubClient: ThermometerClient {
        let events = AsyncStream<ThermometerEvent> { _ in }
        func start() {}
    }

    private func reading(_ celsius: Double, at seconds: TimeInterval) -> ThermometerReading {
        ThermometerReading(profile: 1, celsius: celsius, measuredAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func deleteRemovesOnlyThatReading() {
        let model = ReadingsModel(client: StubClient())
        let a = reading(36.1, at: 100)
        let b = reading(36.5, at: 200)
        model.handle(.reading(a))
        model.handle(.reading(b))

        model.delete(a)

        #expect(model.readings == [b])
    }

    @Test func deleteOfUnknownReadingIsNoOp() {
        let model = ReadingsModel(client: StubClient())
        let a = reading(36.1, at: 100)
        model.handle(.reading(a))

        model.delete(reading(37.0, at: 300))

        #expect(model.readings == [a])
    }
}
