import CloudKit
import Foundation

/// A `HouseholdSync` over a CloudKit record zone. The creator owns the zone in the private
/// database; members reach it through the shared database.
final class CloudKitHouseholdSync: HouseholdSync, ProfileSync {
    static let containerIdentifier = "iCloud.dev.willsawyerrrr.kintemp"
    static let zoneName = "Household"
    static let recordType = "Reading"
    static let profileRecordType = "Profile"

    private let tokenURL: URL
    lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var location: (database: CKDatabase, zoneID: CKRecordZone.ID)?
    private let profileLock = NSLock()
    private var fetchedProfileChanges: [ProfileChange] = []

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

    func delete(recordName: String) async throws {
        let (database, zoneID) = try await resolveLocation()
        let (_, deleteResults) = try await database.modifyRecords(
            saving: [], deleting: [CKRecord.ID(recordName: recordName, zoneID: zoneID)])
        for result in deleteResults.values {
            if case .failure(let error) = result, !Self.isAlreadyDeleted(error) { throw error }
        }
    }

    func fetchChanges() async throws -> HouseholdChanges {
        let (database, zoneID) = try await resolveLocation()
        var readings: [SyncReading] = []
        var deleted: [String] = []
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
                deleted = []
                discardFetchedProfileChanges()
                saveToken(nil)
                continue
            }
            for result in changes.modificationResultsByID.values {
                let record = try result.get().record
                if let reading = Self.reading(from: record) {
                    readings.append(reading)
                } else if let change = Self.profileChange(from: record) {
                    appendFetchedProfileChange(change)
                }
            }
            for deletion in changes.deletions where deletion.recordType == Self.profileRecordType {
                if let slot = Self.profileSlot(recordName: deletion.recordID.recordName) {
                    appendFetchedProfileChange(.reset(slot: slot))
                }
            }
            deleted += changes.deletions.filter { $0.recordType == Self.recordType }.map(\.recordID.recordName)
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        saveToken(token)
        return HouseholdChanges(readings: readings, deletedRecordNames: deleted)
    }

    func uploadProfile(_ profile: Profile) async throws -> ProfileChange {
        let (database, zoneID) = try await resolveLocation()
        var record = Self.profileRecord(for: profile, in: zoneID)
        for _ in 0..<3 {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let result = saveResults[record.recordID] else { throw CKError(.unknownItem) }
            switch result {
            case .success(let saved):
                guard let change = Self.profileChange(from: saved) else { throw CKError(.partialFailure) }
                return change
            case .failure(let error):
                guard let error = error as? CKError, error.code == .serverRecordChanged,
                    let server = error.serverRecord, let remote = Self.profileChange(from: server),
                    case .upsert(_, _, _, let remoteModifiedAt) = remote
                else { throw error }
                if remoteModifiedAt >= profile.modifiedAt ?? .distantPast { return remote }
                Self.fill(server, from: profile)
                record = server
            }
        }
        throw CKError(.serverRecordChanged)
    }

    func takeProfileChanges() -> [ProfileChange] {
        profileLock.withLock {
            defer { fetchedProfileChanges = [] }
            return fetchedProfileChanges
        }
    }

    private func appendFetchedProfileChange(_ change: ProfileChange) {
        profileLock.withLock { fetchedProfileChanges.append(change) }
    }

    private func discardFetchedProfileChanges() {
        profileLock.withLock { fetchedProfileChanges = [] }
    }

    static func profileRecordName(slot: Int) -> String { "profile-\(slot)" }

    static func profileSlot(recordName: String) -> Int? {
        recordName.hasPrefix("profile-") ? Int(recordName.dropFirst("profile-".count)) : nil
    }

    static func profileRecord(for profile: Profile, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: profileRecordType,
            recordID: CKRecord.ID(recordName: profileRecordName(slot: profile.slot), zoneID: zoneID))
        fill(record, from: profile)
        return record
    }

    private static func fill(_ record: CKRecord, from profile: Profile) {
        record["slot"] = profile.slot
        record["name"] = profile.name
        record["ignored"] = profile.isIgnored ? 1 : 0
    }

    static func profileChange(from record: CKRecord) -> ProfileChange? {
        guard record.recordType == profileRecordType,
            let slot = record["slot"] as? Int,
            let name = record["name"] as? String,
            let ignored = record["ignored"] as? Int
        else { return nil }
        return .upsert(
            slot: slot, name: name, isIgnored: ignored != 0, modifiedAt: record.modificationDate ?? .distantPast)
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

    /// A deletion of a record the household no longer holds.
    static func isAlreadyDeleted(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
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
