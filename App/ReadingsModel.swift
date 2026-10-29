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
        let events = client.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        client.start()
    }

    /// Removes `reading` from the list and this phone's store for good, and cancels its pending Health write.
    /// Nothing is written to the thermometer or deleted from CloudKit or Health.
    func delete(_ reading: ThermometerReading) {
        readings.removeAll { $0.id == reading.id }
        sync?.delete(reading)
        health.discard(reading)
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


    /// Uploads the outbox and profile changes and merges what the household shared; says whether the pull found any.
    @discardableResult
    func syncHousehold() async -> SyncOutcome {
        guard let sync else { return .noData }
        await sync.flush()
        await profileSync?.flush()
        guard let fetched = try? await sync.pull() else { return .failed }
        let profilesChanged = profileSync?.pull() ?? false
        fetched.forEach(health.submit)
        readings.append(contentsOf: fetched.filter { !readings.contains($0) })
        readings.sort { $0.measuredAt > $1.measuredAt }
        return fetched.isEmpty && !profilesChanged ? .noData : .newData
    }
}
