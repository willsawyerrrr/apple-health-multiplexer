import SwiftUI

@main
struct KintempApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ReadingsModel(client: CoreThermometerClient(), sync: Self.makeSync())

    @State private var profiles = ProfileBook()

    var body: some Scene {
        WindowGroup {
            ReadingsView(model: model, profiles: profiles)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await model.syncHousehold() } }
                }
        }
    }

    /// `nil` under test, where the app has no iCloud entitlement.
    private static func makeSync() -> ReadingSyncCoordinator? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let directory = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return ReadingSyncCoordinator(
            store: FileReadingStore(url: directory.appending(path: "readings.json")),
            sync: CloudKitHouseholdSync(tokenURL: directory.appending(path: "household-change-token")))
    }
}
