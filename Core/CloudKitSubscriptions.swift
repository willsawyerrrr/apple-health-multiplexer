import CloudKit

/// A `SubscriptionDatabase` over a CloudKit database; pushes are silent (`shouldSendContentAvailable`, no alert).
struct CloudKitSubscriptionDatabase: SubscriptionDatabase {
    let database: CKDatabase

    func subscriptionIDs() async throws -> Set<String> {
        Set(try await database.allSubscriptions().map(\.subscriptionID))
    }

    func subscribe(id: String) async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }
}

extension CloudKitHouseholdSync {
    /// Subscribes the private and shared databases to changes, once each; returns any failures.
    func ensureSubscriptions() async -> [Error] {
        await HouseholdSubscriptions.ensure(
            private: CloudKitSubscriptionDatabase(database: container.privateCloudDatabase),
            shared: CloudKitSubscriptionDatabase(database: container.sharedCloudDatabase))
    }
}
