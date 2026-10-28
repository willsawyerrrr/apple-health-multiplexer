import Foundation

/// A reading attributed to a profile, as stored locally and shared with the household.
struct SyncReading: Codable, Equatable, Identifiable {
    let recordName: String
    let profile: Int
    let celsius: Double
    let measuredAt: Date

    var id: String { recordName }

    init(profile: Int, celsius: Double, measuredAt: Date) {
        self.recordName = Self.recordName(profile: profile, celsius: celsius, measuredAt: measuredAt)
        self.profile = profile
        self.celsius = celsius
        self.measuredAt = measuredAt
    }

    /// `nil` for an unattributed reading, which is never shared.
    init?(_ reading: ThermometerReading) {
        guard let profile = reading.profile else { return nil }
        self.init(profile: profile, celsius: reading.celsius, measuredAt: reading.measuredAt)
    }

    var reading: ThermometerReading {
        ThermometerReading(profile: profile, celsius: celsius, measuredAt: measuredAt)
    }

    /// Deterministic from the profile, the whole-second timestamp and the tenths of a degree, so
    /// every phone derives the same name for the same reading.
    static func recordName(profile: Int, celsius: Double, measuredAt: Date) -> String {
        let seconds = Int(measuredAt.timeIntervalSince1970.rounded(.down))
        let tenths = Int((celsius * 10).rounded())
        return "reading-\(profile)-\(seconds)-\(tenths)"
    }
}
