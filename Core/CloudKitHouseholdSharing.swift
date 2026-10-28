import CloudKit
import Foundation

/// `HouseholdSharing` over a zone-wide `CKShare` on the `Household` zone.
final class CloudKitHouseholdSharing: HouseholdSharing {
    private let container = CKContainer(identifier: CloudKitHouseholdSync.containerIdentifier)

    private let log: (String) -> Void

    /// `log` receives each step and CloudKit failure, for the debug log.
    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    func prepareShare() async throws -> CKShare {
        do {
            return try await createShare()
        } catch {
            log("share failed: \(error.cloudKitDescription)")
            throw error
        }
    }

    private func createShare() async throws -> CKShare {
        let status = try await container.accountStatus()
        log("share: iCloud account \(status.name)")
        guard status == .available else { throw ICloudUnavailableError(status: status.name) }
        let sharedZone = try await container.sharedCloudDatabase.allRecordZones()
            .first { $0.zoneID.zoneName == CloudKitHouseholdSync.zoneName }
        let database: CKDatabase
        let zoneID: CKRecordZone.ID
        if let sharedZone {
            log("share: zone is in the shared database")
            (database, zoneID) = (container.sharedCloudDatabase, sharedZone.zoneID)
        } else {
            let zone = CKRecordZone(zoneName: CloudKitHouseholdSync.zoneName)
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
            log("share: zone saved in the private database")
            (database, zoneID) = (container.privateCloudDatabase, zone.zoneID)
        }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            if let existing = try await database.record(for: shareID) as? CKShare {
                log("share: reusing the existing share")
                return existing
            }
        } catch let error as CKError where error.code == .unknownItem {
            log("share: no existing share")
        }
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Kintemp household"
        let (saveResults, _) = try await database.modifyRecords(
            saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let result = saveResults[share.recordID] else { throw CKError(.unknownItem) }
        guard let saved = try result.get() as? CKShare else { throw CKError(.internalError) }
        log("share: saved")
        return saved
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        _ = try await container.accept(metadata)
    }
}
