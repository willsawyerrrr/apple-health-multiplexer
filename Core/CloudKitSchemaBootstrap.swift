#if DEBUG
import CloudKit
import Foundation
import os

/// Debug-only launch hook that creates the `Household` zone and its share, so CloudKit's
/// Development environment creates the system record types the share needs.
enum CloudKitSchemaBootstrap {
    static let launchArgument = "-BootstrapCloudKitSchema"

    private static let logger = Logger(subsystem: "dev.willsawyerrrr.kintemp", category: "schema-bootstrap")

    /// Whether this launch asked for the bootstrap.
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Runs `CloudKitHouseholdSharing.prepareShare`, the path the Invite button takes, then exits
    /// the process: status 0 on success, 2 when no iCloud account is available, 1 otherwise.
    static func runAndExit() {
        Task {
            let code = await run()
            fflush(stdout)
            exit(code)
        }
    }

    private static func run() async -> Int32 {
        let sharing = CloudKitHouseholdSharing(log: { report("bootstrap: \($0)") })
        do {
            let share = try await sharing.prepareShare()
            report("bootstrap: OK, share \(share.recordID.recordName)")
            return 0
        } catch let error as ICloudUnavailableError {
            report("bootstrap: FAILED, no iCloud account is signed in (\(error.status)). Sign in to Settings > Apple Account in the Simulator.")
            return 2
        } catch {
            report("bootstrap: FAILED, \(error.cloudKitDescription)")
            return 1
        }
    }

    private static func report(_ line: String) {
        print(line)
        logger.notice("\(line, privacy: .public)")
    }
}
#endif
