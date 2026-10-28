import Foundation

/// Deterministic name of a reading, used as its HealthKit sync identifier.
enum HealthRecordName {
    /// `<profile>-<thermometerTimestamp>-<tenthsOfDegree>`.
    static func make(profile: Int, measuredAt: Date, celsius: Double) -> String {
        let timestamp = Int(measuredAt.timeIntervalSince1970.rounded(.down))
        let tenths = Int((celsius * 10).rounded())
        return "\(profile)-\(timestamp)-\(tenths)"
    }
}
