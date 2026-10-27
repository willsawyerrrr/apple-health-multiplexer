import Foundation

/// A body temperature reading attributed to a profile.
struct ThermometerReading: Equatable, Identifiable {
    var id = UUID()
    /// The thermometer profile; `nil` when attribution was ambiguous.
    var profile: Int?
    var celsius: Double
    var measuredAt: Date

    var isAmbiguous: Bool { profile == nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.celsius == rhs.celsius && lhs.measuredAt == rhs.measuredAt
    }
}
