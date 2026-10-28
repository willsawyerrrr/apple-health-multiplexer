import Foundation

/// Persistence for profiles; CloudKit can back it later.
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

    /// Renames `slot`; a blank name restores the default.
    mutating func rename(slot: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(slot) { $0.name = trimmed.isEmpty ? Profile.defaultName(slot: slot) : trimmed }
    }

    mutating func setIgnored(slot: Int, _ isIgnored: Bool) {
        update(slot) { $0.isIgnored = isIgnored }
    }

    mutating func setOwner(slot: Int, _ owner: String?) {
        update(slot) { $0.owner = owner }
    }

    private mutating func update(_ slot: Int, _ change: (inout Profile) -> Void) {
        var profile = profile(slot: slot)
        change(&profile)
        bySlot[slot] = profile
        store.save(bySlot.values.sorted { $0.slot < $1.slot })
    }
}
