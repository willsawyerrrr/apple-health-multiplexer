import Foundation

/// A CloudKit database that can hold the household's change subscription.
protocol SubscriptionDatabase {
    /// Identifiers of the subscriptions the database already holds.
    func subscriptionIDs() async throws -> Set<String>
    /// Saves a silent-push subscription to the database's changes with the given identifier.
    func subscribe(id: String) async throws
}

/// Creates the silent-push subscriptions that deliver household changes.
enum HouseholdSubscriptions {
    static let privateID = "household-private"
    static let sharedID = "household-shared"

    /// Subscribes each database that lacks its subscription. A failure on one database does not stop the
    /// others; the errors are returned.
    @discardableResult
    static func ensure(private privateDatabase: SubscriptionDatabase, shared sharedDatabase: SubscriptionDatabase) async
        -> [Error]
    {
        var errors: [Error] = []
        for (database, id) in [(privateDatabase, privateID), (sharedDatabase, sharedID)] {
            do {
                if try await !database.subscriptionIDs().contains(id) { try await database.subscribe(id: id) }
            } catch {
                errors.append(error)
            }
        }
        return errors
    }
}

/// What a household pull found, for answering a silent push.
enum SyncOutcome: Equatable {
    case newData, noData, failed
}
