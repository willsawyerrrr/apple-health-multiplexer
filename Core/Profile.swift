import Foundation

/// A person (or the guest) measured by one thermometer slot.
struct Profile: Codable, Equatable, Identifiable {
    /// The thermometer slot; slot 0 is the guest slot.
    var slot: Int
    var name: String
    /// The iCloud account that owns the profile, if assigned.
    var owner: String?
    var isIgnored = false
    /// When the name or ignored flag last changed: this phone's clock for a local edit, the
    /// household record's modification date for a synced one. `nil` until first changed or synced.
    var modifiedAt: Date?
    /// Whether a local change to the name or ignored flag awaits upload to the household.
    /// A profile customised before syncing existed is pending until first synced.
    var isPendingUpload = false

    var id: Int { slot }
    var isGuest: Bool { slot == Self.guestSlot }

    /// Whether the profile's readings may be uploaded or written to Health.
    /// The guest slot and ignored profiles are shown only on the phone that read them.
    var isTracked: Bool { !isGuest && !isIgnored }

    static let guestSlot = 0

    /// The slots the thermometer provides.
    static let thermometerSlots = 0...2

    init(slot: Int, name: String? = nil, owner: String? = nil, isIgnored: Bool = false) {
        self.slot = slot
        self.name = name ?? Self.defaultName(slot: slot)
        self.owner = owner
        self.isIgnored = isIgnored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(Int.self, forKey: .slot)
        name = try container.decode(String.self, forKey: .name)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        isPendingUpload =
            try container.decodeIfPresent(Bool.self, forKey: .isPendingUpload)
            ?? (modifiedAt == nil && (name != Self.defaultName(slot: slot) || isIgnored))
    }

    static func defaultName(slot: Int) -> String {
        slot == guestSlot ? "Guest" : "Profile \(slot)"
    }
}
