import Foundation

/// Persistence for profiles on this phone.
protocol ProfileStore {
    func load() -> [Profile]
    func save(_ profiles: [Profile])
}

/// Stores profiles as JSON in `UserDefaults`.
struct UserDefaultsProfileStore: ProfileStore {
    var defaults: UserDefaults = .standard
    var key = "profiles"

    func load() -> [Profile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    func save(_ profiles: [Profile]) {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: key)
    }
}

/// The household's profiles, keyed by slot, persisted through a `ProfileStore`.
struct ProfileDirectory {
    private var bySlot: [Int: Profile]
    private let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
        bySlot = Dictionary(store.load().map { ($0.slot, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The stored profile for `slot`, or a default one.
    func profile(slot: Int) -> Profile { bySlot[slot] ?? Profile(slot: slot) }

    /// The name for `slot`, or "Ambiguous" when the slot is unknown.
    func displayName(slot: Int?) -> String {
        slot.map { profile(slot: $0).name } ?? "Ambiguous"
    }

    /// Slots to list: the thermometer's slots, stored profiles and `observed` slots, ascending.
    func slots(observed: some Sequence<Int> = []) -> [Int] {
        Set(bySlot.keys).union(observed).union(Profile.thermometerSlots).sorted()
    }

    /// Slots with a stored profile.
    var storedSlots: Set<Int> { Set(bySlot.keys) }

    /// Profiles with a local change awaiting upload, ascending by slot.
    var pendingUploads: [Profile] {
        bySlot.values.filter(\.isPendingUpload).sorted { $0.slot < $1.slot }
    }

    /// Renames `slot`; a blank name restores the default.
    mutating func rename(slot: Int, to name: String, at now: Date = .now) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(slot, at: now) { $0.name = trimmed.isEmpty ? Profile.defaultName(slot: slot) : trimmed }
    }

    mutating func setIgnored(slot: Int, _ isIgnored: Bool, at now: Date = .now) {
        edit(slot, at: now) { $0.isIgnored = isIgnored }
    }

    /// Sets the owner; the owner stays on this phone and is never synced.
    mutating func setOwner(slot: Int, _ owner: String?) {
        var profile = profile(slot: slot)
        profile.owner = owner
        save(profile)
    }

    /// Merges a household change: the newer of the local and household versions wins. Returns whether
    /// the profile's name or ignored flag changed.
    @discardableResult
    mutating func apply(_ change: ProfileChange) -> Bool {
        var profile = profile(slot: change.slot)
        let before = profile
        switch change {
        case .upsert(_, let name, let isIgnored, let modifiedAt):
            if let local = profile.modifiedAt, local > modifiedAt { return false }
            profile.name = name
            profile.isIgnored = isIgnored
            profile.modifiedAt = modifiedAt
        case .reset(let slot):
            if profile.isPendingUpload { return false }
            profile.name = Profile.defaultName(slot: slot)
            profile.isIgnored = false
            profile.modifiedAt = nil
        }
        profile.isPendingUpload = false
        guard profile != before else { return false }
        save(profile)
        return profile.name != before.name || profile.isIgnored != before.isIgnored
    }

    /// Records that `uploaded` reached the household and merges `result`, the household's version
    /// afterwards. A profile edited since stays pending.
    @discardableResult
    mutating func finishUpload(of uploaded: Profile, result: ProfileChange) -> Bool {
        var current = profile(slot: uploaded.slot)
        guard current.modifiedAt == uploaded.modifiedAt else { return false }
        current.isPendingUpload = false
        current.modifiedAt = nil
        save(current)
        return apply(result)
    }

    private mutating func edit(_ slot: Int, at now: Date, _ change: (inout Profile) -> Void) {
        var profile = profile(slot: slot)
        let before = profile
        change(&profile)
        guard profile.name != before.name || profile.isIgnored != before.isIgnored else { return }
        profile.modifiedAt = now
        profile.isPendingUpload = true
        save(profile)
    }

    private mutating func save(_ profile: Profile) {
        bySlot[profile.slot] = profile
        store.save(bySlot.values.sorted { $0.slot < $1.slot })
    }
}

/// A change to a profile made by another phone in the household.
enum ProfileChange: Equatable {
    /// The household's current name and ignored flag for `slot`, last modified at `modifiedAt`.
    case upsert(slot: Int, name: String, isIgnored: Bool, modifiedAt: Date)
    /// The household's record for `slot` was deleted, restoring the defaults.
    case reset(slot: Int)

    var slot: Int {
        switch self {
        case .upsert(let slot, _, _, _), .reset(let slot): slot
        }
    }
}
