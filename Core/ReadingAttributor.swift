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

    enum Outcome: Equatable {
        /// The reading, or `nil` when it was filtered out or a duplicate.
        case resolved(ThermometerReading?)
        /// A lone live indication: read the current profile and call
        /// `completeLive(_:profile:)`.
        case needsCurrentProfile
    }

    private struct Key: Hashable {
        var profile: Int?
        var second: Int
        var tenthsOfDegree: Int
    }

    private(set) var clockOffset: TimeInterval = 0
    private var profiles: [UInt32: Int] = [:]
    private var emptyStreak = 0
    private var lastIndicationAt: TimeInterval?
    private var seen: Set<Key> = []

    /// Starts a connection. `clockOffset` is host Unix time minus thermometer
    /// clock. Deduplication state carries across connections.
    mutating func beginSession(clockOffset: TimeInterval) {
        self.clockOffset = clockOffset
        profiles = [:]
        emptyStreak = 0
        lastIndicationAt = nil
    }

    /// Records a 2A75 read. Returns whether polling should continue.
    mutating func observe(_ read: QueueRead) -> Bool {
        switch read {
        case .empty:
            emptyStreak += 1
        case .record(let record):
            emptyStreak = 0
            profiles[record.timestamp] = Int(record.profile)
        }
        return emptyStreak < Self.emptyReadsToStop
    }

    /// Handles an indication received at host time `now` (Unix seconds).
    mutating func receive(_ measurement: TemperatureMeasurement, at now: TimeInterval) -> Outcome {
        let inBatch = lastIndicationAt.map { now - $0 <= Self.batchWindow } ?? false
        lastIndicationAt = now
        guard Self.bodyRange.contains(measurement.celsius) else { return .resolved(nil) }
        if let profile = profiles[measurement.timestamp] {
            return .resolved(finish(measurement, profile: profile))
        }
        return inBatch ? .resolved(finish(measurement, profile: nil)) : .needsCurrentProfile
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
