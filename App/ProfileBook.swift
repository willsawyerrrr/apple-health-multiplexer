import Observation

/// Observable wrapper over `ProfileDirectory` for the UI.
@MainActor @Observable
final class ProfileBook {
    private var directory: ProfileDirectory

    init(store: ProfileStore = UserDefaultsProfileStore()) {
        directory = ProfileDirectory(store: store)
    }

    func profile(slot: Int) -> Profile { directory.profile(slot: slot) }
    func displayName(slot: Int?) -> String { directory.displayName(slot: slot) }
    func slots(observed: some Sequence<Int>) -> [Int] { directory.slots(observed: observed) }
    func rename(slot: Int, to name: String) { directory.rename(slot: slot, to: name) }
    func setIgnored(slot: Int, _ isIgnored: Bool) { directory.setIgnored(slot: slot, isIgnored) }
}
