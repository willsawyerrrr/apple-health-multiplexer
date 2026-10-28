import CloudKit
import Foundation
import Testing

@testable import Kintemp

final class FakeHouseholdSharing: HouseholdSharing {
    var share = CKShare(recordZoneID: CKRecordZone.ID(zoneName: "Household"))
    var failing = false
    var accepted: [String] = []
    var prepareCount = 0
    struct Unreachable: Error {}

    func prepareShare() async throws -> CKShare {
        prepareCount += 1
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
}
