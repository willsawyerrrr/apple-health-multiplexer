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

final class AppDelegate: NSObject, UIApplicationDelegate {
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
