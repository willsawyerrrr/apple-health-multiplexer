import CloudKit
import Foundation

/// `HouseholdSharing` over a zone-wide `CKShare` on the `Household` zone.
final class CloudKitHouseholdSharing: HouseholdSharing {
    private let container = CKContainer(identifier: CloudKitHouseholdSync.containerIdentifier)

    func prepareShare() async throws -> CKShare {
        let sharedZone = try await container.sharedCloudDatabase.allRecordZones()
            .first { $0.zoneID.zoneName == CloudKitHouseholdSync.zoneName }
        let database: CKDatabase
        let zoneID: CKRecordZone.ID
        if let sharedZone {
            (database, zoneID) = (container.sharedCloudDatabase, sharedZone.zoneID)
        } else {
            let zone = CKRecordZone(zoneName: CloudKitHouseholdSync.zoneName)
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
            (database, zoneID) = (container.privateCloudDatabase, zone.zoneID)
        }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare { return existing }
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Kintemp household"
        let (saveResults, _) = try await database.modifyRecords(
            saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let result = saveResults[share.recordID] else { throw CKError(.unknownItem) }
        guard let saved = try result.get() as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }
}
