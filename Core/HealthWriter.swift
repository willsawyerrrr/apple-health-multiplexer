import Foundation

/// A body temperature sample awaiting a write to Apple Health.
struct HealthSample: Codable, Equatable {
    /// The reading's deterministic record name; the HealthKit sync identifier.
    var name: String
    var celsius: Double
    var measuredAt: Date
}

/// Whether the app may write body temperature to Apple Health.
enum HealthWriteStatus {
    case notDetermined, denied, authorized
}

protocol HealthWriter {
    /// The current write access to body temperature. Read access is hidden by HealthKit and not reported.
    func writeStatus() -> HealthWriteStatus
    /// Requests write-only access to body temperature.
    func requestAuthorization() async throws
    /// Writes the sample idempotently. Throws when the write cannot happen yet.
    func write(_ sample: HealthSample) async throws
    /// Deletes the sample whose sync identifier is `name`. Succeeds when there is none; throws when the deletion cannot happen yet.
    func delete(name: String) async throws
}
