import Observation

/// Observable wrapper over `ProfileDirectory` for the UI.
@MainActor @Observable
final class ProfileBook {
    private var directory: ProfileDirectory
    /// Called after a local change that may need uploading.
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: ProfileStore = UserDefaultsProfileStore()) {
        directory = ProfileDirectory(store: store)
    }

    func profile(slot: Int) -> Profile { directory.profile(slot: slot) }
    func displayName(slot: Int?) -> String { directory.displayName(slot: slot) }
    func slots(observed: some Sequence<Int>) -> [Int] { directory.slots(observed: observed) }
    var storedSlots: Set<Int> { directory.storedSlots }
    var pendingUploads: [Profile] { directory.pendingUploads }

    func rename(slot: Int, to name: String) {
        directory.rename(slot: slot, to: name)
        onChange?()
    }

    func setIgnored(slot: Int, _ isIgnored: Bool) {
        directory.setIgnored(slot: slot, isIgnored)
        onChange?()
    }

    /// Merges household changes; returns whether any name or ignored flag changed.
    @discardableResult
    func apply(_ changes: [ProfileChange]) -> Bool {
        changes.reduce(false) { directory.apply($1) || $0 }
    }

    @discardableResult
    func finishUpload(of uploaded: Profile, result: ProfileChange) -> Bool {
        directory.finishUpload(of: uploaded, result: result)
    }
}
