import SwiftUI

typealias AppInvitations = HouseholdInvitations<CloudKitHouseholdSharing>

@main
struct KintempApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReadingsModel
    @State private var profiles: ProfileBook
    @State private var invitations: AppInvitations?

    init() {
        #if DEBUG
        if CloudKitSchemaBootstrap.isRequested { CloudKitSchemaBootstrap.runAndExit() }
        #endif
        let profiles = ProfileBook()
        _profiles = State(initialValue: profiles)
        let cloud = Self.makeCloud()
        let model = ReadingsModel(
            client: CoreThermometerClient(), sync: Self.makeSync(profiles: profiles, cloud: cloud),
            health: HealthSync(writer: HealthKitWriter(), isTracked: { profiles.profile(slot: $0).isTracked }))
        _model = State(initialValue: model)
        RemoteChanges.shared.handler = { await model.syncHousehold() }
        if let cloud { Task { await cloud.ensureSubscriptions() } }
        _invitations = State(
            initialValue: cloud.map { cloud in
                AppInvitations(
                    sharing: CloudKitHouseholdSharing(log: { line in Task { @MainActor in model.log(line) } }),
                    log: { line in Task { @MainActor in model.log(line) } }
                ) {
                    cloud.forgetLocation()
                    await model.syncHousehold()
                }
            })
    }

    var body: some Scene {
        WindowGroup {
            ReadingsView(model: model, profiles: profiles, invitations: invitations)
                .onAppear {
                    ShareAcceptance.shared.handler = { metadata in
                        Task { await invitations?.accept(metadata) }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        Task { await model.syncHousehold() }
                        Task { await model.health.requestAccess() }
                        Task { await model.health.flush() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    Task { await model.health.flush() }
                }
        }
    }

    /// `nil` under test, where the app has no iCloud entitlement.
    private static func makeCloud() -> CloudKitHouseholdSync? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let directory = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return CloudKitHouseholdSync(tokenURL: directory.appending(path: "household-change-token"))
    }

    private static func makeSync(profiles: ProfileBook, cloud: CloudKitHouseholdSync?) -> ReadingSyncCoordinator? {
        guard let cloud,
            let directory = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return ReadingSyncCoordinator(
            store: FileReadingStore(url: directory.appending(path: "readings.json")),
            sync: cloud, isTracked: { profiles.profile(slot: $0).isTracked })
    }
}
