import CloudKit
import UIKit

/// Hands share links the user opens to the app, holding one that arrives before a handler is set.
@MainActor
final class ShareAcceptance {
    static let shared = ShareAcceptance()

    private var pending: [CKShare.Metadata] = []
    var handler: ((CKShare.Metadata) -> Void)? {
        didSet {
            guard let handler else { return }
            let queued = pending
            pending = []
            queued.forEach(handler)
        }
    }

    func receive(_ metadata: CKShare.Metadata) {
        if let handler { handler(metadata) } else { pending.append(metadata) }
    }
}

/// Runs the household sync for a silent push; set at launch so a background launch can answer it.
@MainActor
final class RemoteChanges {
    static let shared = RemoteChanges()

    var handler: (() async -> SyncOutcome)?

    func receive() async -> SyncOutcome { await handler?() ?? .noData }
}

extension SyncOutcome {
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) is CKDatabaseNotification else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in completionHandler(await RemoteChanges.shared.receive().fetchResult) }
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let metadata = options.cloudKitShareMetadata {
            Task { @MainActor in ShareAcceptance.shared.receive(metadata) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in ShareAcceptance.shared.receive(metadata) }
    }
}
