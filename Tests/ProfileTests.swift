import Foundation
import Testing

@testable import Kintemp

private final class MemoryStore: ProfileStore {
    var profiles: [Profile] = []
    func load() -> [Profile] { profiles }
    func save(_ profiles: [Profile]) { self.profiles = profiles }
}

struct ProfileTests {
    @Test func guestSlotIsNotTracked() {
        let guest = Profile(slot: 0)
        #expect(guest.isGuest)
        #expect(!guest.isTracked)
        #expect(guest.name == "Guest")
    }

    @Test func namedSlotIsTrackedUnlessIgnored() {
        var profile = Profile(slot: 2)
        #expect(profile.isTracked)
        #expect(profile.name == "Profile 2")
        profile.isIgnored = true
        #expect(!profile.isTracked)
    }

    @Test func guestStaysUntrackedWhenAssigned() {
        #expect(!Profile(slot: 0, name: "Sam", owner: "sam").isTracked)
    }

    @Test func renamePersistsAndTrims() {
        let store = MemoryStore()
        var directory = ProfileDirectory(store: store)
        directory.rename(slot: 1, to: "  Alex ")
        #expect(directory.displayName(slot: 1) == "Alex")
        #expect(ProfileDirectory(store: store).displayName(slot: 1) == "Alex")
    }

    @Test func blankRenameRestoresDefault() {
        var directory = ProfileDirectory(store: MemoryStore())
        directory.rename(slot: 1, to: "Alex")
        directory.rename(slot: 1, to: "   ")
        #expect(directory.displayName(slot: 1) == "Profile 1")
    }

    @Test func ambiguousReadingHasNoSlotName() {
        #expect(ProfileDirectory(store: MemoryStore()).displayName(slot: nil) == "Ambiguous")
    }

    @Test func slotsIncludeGuestStoredAndObserved() {
        let store = MemoryStore()
        store.profiles = [Profile(slot: 3)]
        let directory = ProfileDirectory(store: store)
        #expect(directory.slots(observed: [1, 3]) == [0, 1, 3])
    }

    @Test func ignoredAndOwnerPersist() {
        let store = MemoryStore()
        var directory = ProfileDirectory(store: store)
        directory.setIgnored(slot: 2, true)
        directory.setOwner(slot: 2, "me")
        let reloaded = ProfileDirectory(store: store).profile(slot: 2)
        #expect(reloaded.isIgnored)
        #expect(reloaded.owner == "me")
    }

    @Test func userDefaultsStoreRoundTrips() {
        let defaults = UserDefaults(suiteName: "ProfileTests-\(UUID())")!
        let store = UserDefaultsProfileStore(defaults: defaults)
        store.save([Profile(slot: 1, name: "Alex")])
        #expect(store.load() == [Profile(slot: 1, name: "Alex")])
    }
}
