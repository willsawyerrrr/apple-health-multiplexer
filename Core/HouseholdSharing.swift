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

    @ObservationIgnored private let sharing: Sharing
    @ObservationIgnored private let onAccepted: () async -> Void

    /// `onAccepted` runs after a share is accepted, so sync can switch to the shared zone.
    init(sharing: Sharing, onAccepted: @escaping () async -> Void) {
        self.sharing = sharing
        self.onAccepted = onAccepted
    }

    /// Prepares the share and presents it; a failure sets `errorMessage`.
    func invite() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        errorMessage = nil
        do {
            presentedShare = try await sharing.prepareShare()
        } catch {
            errorMessage = "Couldn't prepare the invitation: \(error.localizedDescription)"
        }
    }

    /// Joins the incoming household, then runs `onAccepted`; a failure sets `errorMessage`.
    func accept(_ incoming: Sharing.Incoming) async {
        guard !isAccepting else { return }
        isAccepting = true
        defer { isAccepting = false }
        errorMessage = nil
        do {
            try await sharing.accept(incoming)
        } catch {
            errorMessage = "Couldn't join the household: \(error.localizedDescription)"
            return
        }
        await onAccepted()
    }
}
