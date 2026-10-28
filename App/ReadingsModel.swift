import Foundation
import Observation

@MainActor @Observable
final class ReadingsModel {
    private(set) var state: ConnectionState = .waiting
    private(set) var readings: [ThermometerReading] = []
    private(set) var logLines: [String] = []

    private static let maxLogLines = 300
    private let client: ThermometerClient
    private let sync: ReadingSyncCoordinator?
    let health: HealthSync
    /// Shares profile names with the household; set once the household sync exists.
    var profileSync: ProfileSyncCoordinator?

    init(client: ThermometerClient, sync: ReadingSyncCoordinator? = nil, health: HealthSync) {
        self.client = client
        self.sync = sync
        self.health = health
        readings = (sync?.storedReadings ?? []).sorted { $0.measuredAt > $1.measuredAt }
        health.storedReadings = { [weak self] in self?.readings ?? [] }
        health.backfill()
        let events = client.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        client.start()
    }

    /// Removes `reading` from the list and this phone's store, and queues its deletion from the household's
    /// CloudKit copy and from Apple Health, retrying until each succeeds. Nothing is written to the thermometer.
    func delete(_ reading: ThermometerReading) {
        readings.removeAll { $0.id == reading.id }
        if let name = reading.recordName { health.remove(recordNames: [name]) }
        guard let sync else { return }
        sync.delete(reading)
        Task { await sync.flush() }
    }

    func handle(_ event: ThermometerEvent) {
        switch event {
        case .state(let state):
            self.state = state
        case .reading(let reading):
            if sync?.isDeleted(reading) == true { return }
            readings.append(reading)
            readings.sort { $0.measuredAt > $1.measuredAt }
            health.submit(reading)
            if let sync {
                sync.record(reading)
                Task { await sync.flush() }
            }
        case .log(let line):
            log(line)
        }
    }

    /// Appends a timestamped line to the bounded debug log.
    func log(_ line: String) {
        logLines.append("\(Date.now.formatted(date: .omitted, time: .standard)) \(line)")
        if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
    }


    /// Merges the household's changes, removing readings it deleted, then deletes queued household copies
    /// and uploads the outbox and profile changes; says whether the pull found any change. Pulling first lets
    /// a deletion remove a reading still waiting in the outbox.
    @discardableResult
    func syncHousehold() async -> SyncOutcome {
        guard let sync else { return .noData }
        let pulled = try? await sync.pull()
        await sync.flush()
        await profileSync?.flush()
        guard let pulled else { return .failed }
        let profilesChanged = profileSync?.pull() ?? false
        let deleted = Set(pulled.deletedRecordNames)
        readings.removeAll { $0.recordName.map(deleted.contains) == true }
        health.remove(recordNames: pulled.deletedRecordNames)
        pulled.added.forEach(health.submit)
        readings.append(contentsOf: pulled.added.filter { !readings.contains($0) })
        readings.sort { $0.measuredAt > $1.measuredAt }
        return pulled.added.isEmpty && pulled.deletedRecordNames.isEmpty && !profilesChanged ? .noData : .newData
    }
}
