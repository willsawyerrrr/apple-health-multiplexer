import CloudKit
import Foundation
import Observation

/// Creates the household share and joins one.
protocol HouseholdSharing: AnyObject {
    /// What the system hands the app when the user opens a share link.
    associatedtype Incoming

    /// The household's share, created (read-write participants, private by default) if none exists.
    func prepareShare() async throws -> CKShare
    /// Joins the household that sent the share.
    func accept(_ incoming: Incoming) async throws
}

/// Drives the invitation flow: preparing the share to present and accepting an incoming one.
@MainActor
@Observable
final class HouseholdInvitations<Sharing: HouseholdSharing> {
    /// The share to present; the UI clears it when the sharing sheet closes.
    var presentedShare: CKShare?
    private(set) var isPreparing = false
    private(set) var isAccepting = false
    var errorMessage: String?
    /// Whether the failure behind `errorMessage` came from preparing the share, so the alert can offer a retry.
    private(set) var canRetryInvite = false

    @ObservationIgnored private let sharing: Sharing
    @ObservationIgnored private let onAccepted: () async -> Void
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let log: (String) -> Void

    /// `onAccepted` runs after a share is accepted, so sync can switch to the shared zone.
    /// Preparing the share gives up after `timeout`; `log` receives each failure.
    init(
        sharing: Sharing, timeout: Duration = .seconds(30), log: @escaping (String) -> Void = { _ in },
        onAccepted: @escaping () async -> Void
    ) {
        self.sharing = sharing
        self.timeout = timeout
        self.log = log
        self.onAccepted = onAccepted
    }

    /// Prepares the share and presents it; a failure, including a timeout, sets `errorMessage`
    /// and `canRetryInvite`.
    func invite() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        errorMessage = nil
        canRetryInvite = false
        let sharing = sharing
        do {
            presentedShare = try await withTimeout(timeout) { try await sharing.prepareShare() }
        } catch {
            report("Couldn't prepare the invitation", error)
            canRetryInvite = true
        }
    }

    /// Reports a failure of the system sharing sheet.
    func sharingFailed(_ error: Error) {
        report("Couldn't save the invitation", error)
        canRetryInvite = true
    }

    /// Joins the incoming household, then runs `onAccepted`; a failure sets `errorMessage`.
    func accept(_ incoming: Sharing.Incoming) async {
        guard !isAccepting else { return }
        isAccepting = true
        defer { isAccepting = false }
        errorMessage = nil
        canRetryInvite = false
        do {
            try await sharing.accept(incoming)
        } catch {
            report("Couldn't join the household", error)
            return
        }
        await onAccepted()
    }
}

extension HouseholdInvitations {
    private func report(_ prefix: String, _ error: Error) {
        let description = error.cloudKitDescription
        log("\(prefix): \(description)")
        errorMessage = [prefix + ":", error.friendlyExplanation, description].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Runs `operation`, throwing `HouseholdTimeoutError` if it hasn't finished within `timeout`.
/// Returns at the deadline even when `operation` ignores cancellation.
func withTimeout<T>(_ timeout: Duration, _ operation: @escaping () async throws -> T) async throws -> T {
    let gate = TimeoutGate<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.continuation = continuation
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.finish(.failure(HouseholdTimeoutError(seconds: Int(timeout.components.seconds))))
        }
        let work = Task {
            do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
            timer.cancel()
        }
        gate.onTimeout = { work.cancel() }
    }
}

private final class TimeoutGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?
    var onTimeout: (() -> Void)?

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
        if case .failure(let error) = result, error is HouseholdTimeoutError { onTimeout?() }
    }
}
