import CloudKit
import Foundation

/// A `HouseholdSync` over a CloudKit record zone. The creator owns the zone in the private
/// database; members reach it through the shared database.
final class CloudKitHouseholdSync: HouseholdSync {
    static let containerIdentifier = "iCloud.dev.willsawyerrrr.kintemp"
    static let zoneName = "Household"
    static let recordType = "Reading"

    private let tokenURL: URL
    lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var location: (database: CKDatabase, zoneID: CKRecordZone.ID)?

    init(tokenURL: URL) {
        self.tokenURL = tokenURL
    }

    /// Re-resolves the zone on the next call, after the household's share is accepted.
    func forgetLocation() {
        location = nil
    }

    func upload(_ reading: SyncReading) async throws {
        let (database, zoneID) = try await resolveLocation()
        let record = Self.record(for: reading, in: zoneID)
        let (saveResults, _) = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        for result in saveResults.values {
            if case .failure(let error) = result, !Self.isDuplicate(error) { throw error }
        }
    }

    func fetchChanges() async throws -> [SyncReading] {
        let (database, zoneID) = try await resolveLocation()
        var readings: [SyncReading] = []
        var token = loadToken()
        var moreComing = true
        while moreComing {
            let changes: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                readings = []
                saveToken(nil)
                continue
            }
            for result in changes.modificationResultsByID.values {
                if let reading = Self.reading(from: try result.get().record) { readings.append(reading) }
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        saveToken(token)
        return readings
    }

    static func record(for reading: SyncReading, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: recordType, recordID: CKRecord.ID(recordName: reading.recordName, zoneID: zoneID))
        record["profile"] = reading.profile
        record["celsius"] = reading.celsius
        record["measuredAt"] = reading.measuredAt
        return record
    }

    static func reading(from record: CKRecord) -> SyncReading? {
        guard record.recordType == recordType,
            let profile = record["profile"] as? Int,
            let celsius = record["celsius"] as? Double,
            let measuredAt = record["measuredAt"] as? Date
        else { return nil }
        return SyncReading(profile: profile, celsius: celsius, measuredAt: measuredAt)
    }

    /// A save the household already holds: the record name is deterministic, so a conflict means
    /// the same reading is stored.
    static func isDuplicate(_ error: Error) -> Bool {
        (error as? CKError)?.code == .serverRecordChanged
    }

    /// The shared zone when this phone is a member; otherwise the zone this phone owns, created on demand.
    private func resolveLocation() async throws -> (database: CKDatabase, zoneID: CKRecordZone.ID) {
        if let location { return location }
        let shared = try await container.sharedCloudDatabase.allRecordZones()
            .first { $0.zoneID.zoneName == Self.zoneName }
        let resolved: (CKDatabase, CKRecordZone.ID)
        if let shared {
            resolved = (container.sharedCloudDatabase, shared.zoneID)
        } else {
            let zone = CKRecordZone(zoneName: Self.zoneName)
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
            resolved = (container.privateCloudDatabase, zone.zoneID)
        }
        location = resolved
        return resolved
    }

    private func loadToken() -> CKServerChangeToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken?) {
        guard let token,
            let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else {
            try? FileManager.default.removeItem(at: tokenURL)
            return
        }
        try? data.write(to: tokenURL, options: .atomic)
    }
}
