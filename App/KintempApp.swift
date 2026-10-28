import SwiftUI

@main
struct KintempApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReadingsModel
    @State private var profiles: ProfileBook

    init() {
        let profiles = ProfileBook()
        _profiles = State(initialValue: profiles)
        _model = State(
            initialValue: ReadingsModel(client: CoreThermometerClient(), sync: Self.makeSync(profiles: profiles)))
    }

    var body: some Scene {
        WindowGroup {
            ReadingsView(model: model, profiles: profiles)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await model.syncHousehold() } }
                }
        }
    }

    /// `nil` under test, where the app has no iCloud entitlement.
    private static func makeSync(profiles: ProfileBook) -> ReadingSyncCoordinator? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let directory = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return ReadingSyncCoordinator(
            store: FileReadingStore(url: directory.appending(path: "readings.json")),
            sync: CloudKitHouseholdSync(tokenURL: directory.appending(path: "household-change-token")),
            isTracked: { profiles.profile(slot: $0).isTracked })
    }
}
