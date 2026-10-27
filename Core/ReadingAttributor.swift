import Foundation

/// Pairs temperature indications with queue records, corrects timestamps to
/// host time, and filters and deduplicates readings. Pure: callers supply every
/// input, including the times.
struct ReadingAttributor {
    static let bodyRange = 32.0...43.0
    /// Indications closer together than this belong to one batch.
    static let batchWindow: TimeInterval = 1
    /// Consecutive empty queue reads that end polling.
    static let emptyReadsToStop = 3

    /// What a call produced.
    struct Update: Equatable {
        /// Finalised readings, in arrival order.
        var readings: [ThermometerReading] = []
        /// Lone live indications: read the current profile for each, in order,
        /// and call `completeLive(_:profile:)`.
        var needsCurrentProfile: [TemperatureMeasurement] = []
    }

    private struct Pending {
        var measurement: TemperatureMeasurement
        var receivedAt: TimeInterval
    }

    private struct Key: Hashable {
        var profile: Int?
        var second: Int
        var tenthsOfDegree: Int
    }

    private(set) var clockOffset: TimeInterval = 0
    private var profiles: [UInt32: Int] = [:]
    private var emptyStreak = 0
    private var pollFinished = false
    private var indicationTimes: [TimeInterval] = []
    private var pending: [Pending] = []
    private var seen: Set<Key> = []

    /// Starts a connection. `clockOffset` is host Unix time minus thermometer
    /// clock. Deduplication state carries across connections.
    mutating func beginSession(clockOffset: TimeInterval) {
        self.clockOffset = clockOffset
        profiles = [:]
        emptyStreak = 0
        pollFinished = false
        indicationTimes = []
        pending = []
    }

    /// Records a 2A75 read and finalises the pending indication it matches.
    /// When polling finishes (three consecutive empty reads), finalises every
    /// indication still unmatched. Returns whether polling should continue.
    mutating func observe(_ read: QueueRead) -> (keepPolling: Bool, update: Update) {
        var update = Update()
        switch read {
        case .empty:
            emptyStreak += 1
        case .record(let record):
            emptyStreak = 0
            let profile = Int(record.profile)
            profiles[record.timestamp] = profile
            let matched = pending.filter { $0.measurement.timestamp == record.timestamp }
            pending.removeAll { $0.measurement.timestamp == record.timestamp }
            update.readings = matched.compactMap { finish($0.measurement, profile: profile) }
        }
        guard emptyStreak >= Self.emptyReadsToStop else { return (true, update) }
        pollFinished = true
        for entry in pending { settle(entry, into: &update) }
        pending = []
        return (false, update)
    }

    /// Handles an indication received at host time `now` (Unix seconds). It is
    /// finalised once its record is polled, or when polling finishes.
    mutating func receive(_ measurement: TemperatureMeasurement, at now: TimeInterval) -> Update {
        indicationTimes.append(now)
        var update = Update()
        guard Self.bodyRange.contains(measurement.celsius) else { return update }
        if let profile = profiles[measurement.timestamp] {
            update.readings = finish(measurement, profile: profile).map { [$0] } ?? []
        } else if pollFinished {
            settle(Pending(measurement: measurement, receivedAt: now), into: &update)
        } else {
            pending.append(Pending(measurement: measurement, receivedAt: now))
        }
        return update
    }

    /// Finalises an unmatched indication: a lone one needs the current
    /// profile, any other is ambiguous.
    private mutating func settle(_ entry: Pending, into update: inout Update) {
        let neighbours = indicationTimes.filter { abs($0 - entry.receivedAt) <= Self.batchWindow }.count - 1
        if neighbours == 0 {
            update.needsCurrentProfile.append(entry.measurement)
        } else if let reading = finish(entry.measurement, profile: nil) {
            update.readings.append(reading)
        }
    }

    /// Finishes a lone live indication with the profile read from 2A78.
    mutating func completeLive(_ measurement: TemperatureMeasurement, profile: Int) -> ThermometerReading? {
        finish(measurement, profile: profile)
    }

    private mutating func finish(_ measurement: TemperatureMeasurement, profile: Int?) -> ThermometerReading? {
        let measuredAt = Date(timeIntervalSince1970: Double(measurement.timestamp) + clockOffset)
        let key = Key(
            profile: profile,
            second: Int(measuredAt.timeIntervalSince1970.rounded(.down)),
            tenthsOfDegree: Int((measurement.celsius * 10).rounded())
        )
        guard seen.insert(key).inserted else { return nil }
        return ThermometerReading(profile: profile, celsius: measurement.celsius, measuredAt: measuredAt)
    }
}
