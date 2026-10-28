import Foundation

/// A body temperature sample awaiting a write to Apple Health.
struct HealthSample: Codable, Equatable {
    /// The reading's deterministic record name; the HealthKit sync identifier.
    var name: String
    var celsius: Double
    var measuredAt: Date
}

protocol HealthWriter {
    /// Requests write-only access to body temperature.
    func requestAuthorization() async throws
    /// Writes the sample idempotently. Throws when the write cannot happen yet.
    func write(_ sample: HealthSample) async throws
}
