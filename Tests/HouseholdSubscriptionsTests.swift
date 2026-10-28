import Testing

@testable import Kintemp

@Suite struct HouseholdSubscriptionsTests {
    private final class FakeDatabase: SubscriptionDatabase {
        struct Failure: Error {}
        var ids: Set<String>
        var failing = false
        private(set) var subscribed: [String] = []

        init(ids: Set<String> = []) { self.ids = ids }

        func subscriptionIDs() async throws -> Set<String> {
            if failing { throw Failure() }
            return ids
        }

        func subscribe(id: String) async throws {
            if failing { throw Failure() }
            subscribed.append(id)
            ids.insert(id)
        }
    }

    @Test func subscribesBothDatabasesWhenMissing() async {
        let privateDatabase = FakeDatabase()
        let sharedDatabase = FakeDatabase()

        let errors = await HouseholdSubscriptions.ensure(private: privateDatabase, shared: sharedDatabase)

        #expect(errors.isEmpty)
        #expect(privateDatabase.subscribed == [HouseholdSubscriptions.privateID])
        #expect(sharedDatabase.subscribed == [HouseholdSubscriptions.sharedID])
    }

    @Test func isIdempotent() async {
        let privateDatabase = FakeDatabase()
        let sharedDatabase = FakeDatabase()
        await HouseholdSubscriptions.ensure(private: privateDatabase, shared: sharedDatabase)
        await HouseholdSubscriptions.ensure(private: privateDatabase, shared: sharedDatabase)

        #expect(privateDatabase.subscribed.count == 1)
        #expect(sharedDatabase.subscribed.count == 1)
    }

    @Test func skipsADatabaseThatAlreadyHasItsSubscription() async {
        let privateDatabase = FakeDatabase(ids: [HouseholdSubscriptions.privateID])
        let sharedDatabase = FakeDatabase()

        await HouseholdSubscriptions.ensure(private: privateDatabase, shared: sharedDatabase)

        #expect(privateDatabase.subscribed.isEmpty)
        #expect(sharedDatabase.subscribed == [HouseholdSubscriptions.sharedID])
    }

    @Test func aFailureDoesNotStopTheOtherDatabase() async {
        let privateDatabase = FakeDatabase()
        privateDatabase.failing = true
        let sharedDatabase = FakeDatabase()

        let errors = await HouseholdSubscriptions.ensure(private: privateDatabase, shared: sharedDatabase)

        #expect(errors.count == 1)
        #expect(sharedDatabase.subscribed == [HouseholdSubscriptions.sharedID])
    }
}
