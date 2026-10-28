import CloudKit
import Foundation
import Testing

@testable import Kintemp

final class FakeHouseholdSharing: HouseholdSharing {
    var share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: "Household"))
    var failing = false
    var error: Error?
    var accepted: [String] = []
    var prepareCount = 0
    var hangs = false
    struct Unreachable: Error {}

    func prepareShare() async throws -> CKShare {
        prepareCount += 1
        if hangs { try await Task.sleep(for: .seconds(3600)) }
        if let error { throw error }
        if failing { throw Unreachable() }
        return share
    }

    func accept(_ incoming: String) async throws {
        if failing { throw Unreachable() }
        accepted.append(incoming)
    }
}

@MainActor
@Suite struct HouseholdInvitationsTests {
    @Test func inviteSetsTheShareToPresent() async {
        let sharing = FakeHouseholdSharing()
        let invitations = HouseholdInvitations(sharing: sharing) {}
        await invitations.invite()
        #expect(invitations.presentedShare === sharing.share)
        #expect(invitations.errorMessage == nil)
        #expect(!invitations.isPreparing)
    }

    @Test func inviteFailureSetsErrorAndPresentsNothing() async {
        let sharing = FakeHouseholdSharing()
        sharing.failing = true
        let invitations = HouseholdInvitations(sharing: sharing) {}
        await invitations.invite()
        #expect(invitations.presentedShare == nil)
        #expect(invitations.errorMessage?.hasPrefix("Couldn't prepare the invitation") == true)
    }

    @Test func acceptJoinsThenNotifies() async {
        let sharing = FakeHouseholdSharing()
        var notified = 0
        let invitations = HouseholdInvitations(sharing: sharing) { notified += 1 }
        await invitations.accept("metadata")
        #expect(sharing.accepted == ["metadata"])
        #expect(notified == 1)
        #expect(invitations.errorMessage == nil)
    }

    @Test func acceptFailureSetsErrorAndSkipsNotification() async {
        let sharing = FakeHouseholdSharing()
        sharing.failing = true
        var notified = 0
        let invitations = HouseholdInvitations(sharing: sharing) { notified += 1 }
        await invitations.accept("metadata")
        #expect(notified == 0)
        #expect(invitations.errorMessage?.hasPrefix("Couldn't join the household") == true)
    }

    @Test func aSuccessfulInviteClearsEarlierError() async {
        let sharing = FakeHouseholdSharing()
        sharing.failing = true
        let invitations = HouseholdInvitations(sharing: sharing) {}
        await invitations.invite()
        sharing.failing = false
        await invitations.invite()
        #expect(invitations.errorMessage == nil)
        #expect(invitations.presentedShare != nil)
    }

    @Test func inviteFailureCanBeRetried() async {
        let sharing = FakeHouseholdSharing()
        sharing.failing = true
        let invitations = HouseholdInvitations(sharing: sharing) {}
        await invitations.invite()
        #expect(invitations.canRetryInvite)
        sharing.failing = false
        await invitations.invite()
        #expect(invitations.presentedShare === sharing.share)
        #expect(!invitations.canRetryInvite)
    }

    @Test func aHangingPrepareTimesOutWithAnError() async {
        let sharing = FakeHouseholdSharing()
        sharing.hangs = true
        var logged: [String] = []
        let invitations = HouseholdInvitations(sharing: sharing, timeout: .milliseconds(50), log: { logged.append($0) }) {}
        await invitations.invite()
        #expect(invitations.presentedShare == nil)
        #expect(invitations.errorMessage?.contains("didn't respond within") == true)
        #expect(invitations.canRetryInvite)
        #expect(!invitations.isPreparing)
        #expect(logged.count == 1)
    }

    @Test func cloudKitErrorsShowTheirCodeInTheMessageAndLog() async {
        let sharing = FakeHouseholdSharing()
        sharing.error = CKError(.notAuthenticated)
        var logged: [String] = []
        let invitations = HouseholdInvitations(sharing: sharing, log: { logged.append($0) }) {}
        await invitations.invite()
        #expect(invitations.errorMessage?.contains("CKError 9 notAuthenticated") == true)
        #expect(logged.first?.contains("notAuthenticated") == true)
    }

    @Test func sharingSheetFailureSurfacesWithRetry() {
        let invitations = HouseholdInvitations(sharing: FakeHouseholdSharing()) {}
        invitations.sharingFailed(CKError(.permissionFailure))
        #expect(invitations.errorMessage?.contains("permissionFailure") == true)
        #expect(invitations.canRetryInvite)
    }

    @Test func aMissingShareTypeInProductionGetsAFriendlyExplanation() async {
        let sharing = FakeHouseholdSharing()
        sharing.error = CKError(
            .serverRejectedRequest,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create new type cloudkit.share in production schema"])
        let invitations = HouseholdInvitations(sharing: sharing) {}
        await invitations.invite()
        #expect(invitations.errorMessage?.contains("aren't set up in iCloud yet") == true)
        #expect(invitations.errorMessage?.contains("cloudkit.share in production schema") == true)
    }
}
