import Foundation

/// A person (or the guest) measured by one thermometer slot.
struct Profile: Codable, Equatable, Identifiable {
    /// The thermometer slot; slot 0 is the guest slot.
    var slot: Int
    var name: String
    /// The iCloud account that owns the profile, if assigned.
    var owner: String?
    var isIgnored = false

    var id: Int { slot }
    var isGuest: Bool { slot == Self.guestSlot }

    /// Whether the profile's readings may be uploaded or written to Health.
    /// The guest slot and ignored profiles are shown only on the phone that read them.
    var isTracked: Bool { !isGuest && !isIgnored }

    static let guestSlot = 0

    init(slot: Int, name: String? = nil, owner: String? = nil, isIgnored: Bool = false) {
        self.slot = slot
        self.name = name ?? Self.defaultName(slot: slot)
        self.owner = owner
        self.isIgnored = isIgnored
    }

    static func defaultName(slot: Int) -> String {
        slot == guestSlot ? "Guest" : "Profile \(slot)"
    }
}
