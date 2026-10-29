import Foundation
import Observation

@MainActor @Observable
final class ReadingsModel {
    private(set) var state: ConnectionState = .waiting
    private(set) var readings: [ThermometerReading] = []
    /// The mask last read from the thermometer, once it has connected.
    private(set) var enabledSlots: EnabledSlotMask?
    /// Slot edits not yet confirmed on the thermometer (`true` enables).
    private(set) var pendingSlotEdits: [Int: Bool] = [:]
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

    /// The slots to list: the thermometer's mask with pending edits applied, or `nil` before it has been read.
    var visibleSlots: [Int]? {
        enabledSlots?.applying(pendingSlotEdits).slots
    }

    /// The lowest slot for a new person: not enabled, and holding no stored profile or reading. `nil` before
    /// the mask is read or when all 100 slots are taken.
    func slotForNewPerson(reserved: Set<Int>) -> Int? {
        enabledSlots?.applying(pendingSlotEdits)
            .lowestFreeSlot(reserved: reserved.union(readings.compactMap(\.profile)))
    }

    /// Queues enabling `slot` on the thermometer. The thermometer's selection is never touched.
    func addSlot(_ slot: Int) { setSlot(slot, enabled: true) }

    /// Queues disabling `slot` on the thermometer. Its readings, name and Health data are kept.
    func removeSlot(_ slot: Int) { setSlot(slot, enabled: false) }

    private func setSlot(_ slot: Int, enabled: Bool) {
        pendingSlotEdits[slot] = enabled
        client.setSlot(slot, enabled: enabled)
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
        case .enabledSlots(let mask, let pending):
            enabledSlots = mask
            pendingSlotEdits = pending
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
