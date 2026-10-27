import Foundation
import Testing

@testable import AppleHealthMultiplexer

struct ReadingAttributorTests {
    private let offset: TimeInterval = 123

    private struct Harness {
        var attributor = ReadingAttributor()
        var readings: [ThermometerReading] = []
        var live: [TemperatureMeasurement] = []
        var keepPolling = true

        init(offset: TimeInterval) { attributor.beginSession(clockOffset: offset) }

        mutating func apply(_ update: ReadingAttributor.Update) {
            readings += update.readings
            live += update.needsCurrentProfile
        }

        mutating func indicate(_ ts: UInt32, _ celsius: Double, at time: TimeInterval) {
            apply(attributor.receive(TemperatureMeasurement(celsius: celsius, timestamp: ts), at: time))
        }

        mutating func poll(_ read: QueueRead) {
            let result = attributor.observe(read)
            keepPolling = result.keepPolling
            apply(result.update)
        }

        mutating func drain() { for _ in 0..<3 { poll(.empty) } }
    }

    @Test func attributesRealBatchByTimestamp() {
        var h = Harness(offset: offset)
        h.poll(record(ts: fixtures[0].ts, profile: fixtures[0].profile))
        for (i, f) in fixtures.enumerated() {
            h.indicate(f.ts, f.celsius, at: 1000 + Double(i) * 0.15)
            h.poll(record(ts: f.ts, profile: f.profile))
        }
        h.drain()
        #expect(h.readings.map(\.profile) == [2, 1, 2, 1, 1, 2])
        #expect(h.readings.map(\.celsius) == [35.6, 36.0, 35.9, 36.2, 36.4, 36.1])
        #expect(h.live.isEmpty)
    }

    @Test func recordsArrivingAfterIndicationsAttributeTheBatch() {
        // Arrival order captured from the device: each record is read after
        // its indication, except the newest, which is read before subscribing.
        let indications: [(UInt32, Double)] = [
            (1_793_120_814, 35.6), (1_793_120_810, 25.1), (1_793_120_805, 26.5), (1_793_120_801, 36.0),
            (1_793_120_794, 35.8), (1_793_120_791, 35.7), (1_793_120_785, 24.5), (1_793_120_781, 36.4),
            (1_793_120_777, 28.0), (1_793_120_773, 36.1), (1_793_120_768, 24.5),
        ]
        let profiles: [UInt32: Int] = [
            1_793_120_814: 2, 1_793_120_810: 2, 1_793_120_805: 2, 1_793_120_801: 2, 1_793_120_794: 1,
            1_793_120_791: 1, 1_793_120_785: 2, 1_793_120_781: 2, 1_793_120_777: 1, 1_793_120_773: 0,
            1_793_120_768: 2,
        ]
        var h = Harness(offset: offset)
        h.poll(record(ts: 1_793_120_814, profile: 2, index: 11))
        for (i, (ts, celsius)) in indications.enumerated() {
            h.indicate(ts, celsius, at: 1000 + Double(i) * 0.15)
            h.poll(record(ts: ts, profile: profiles[ts]!, index: UInt16(11 - i)))
            if ts == 1_793_120_791 { h.poll(record(ts: ts, profile: 1, index: 6)) }
        }
        #expect(h.readings.isEmpty == false)
        h.drain()
        #expect(h.readings.map(\.celsius) == [35.6, 36.0, 35.8, 35.7, 36.4, 36.1])
        #expect(h.readings.map(\.profile) == [2, 2, 1, 1, 2, 0])
        #expect(h.readings.allSatisfy { !$0.isAmbiguous })
        #expect(h.live.isEmpty)
        #expect(!h.keepPolling)
    }

    @Test func indicationsWaitForTheirRecord() {
        var h = Harness(offset: offset)
        h.indicate(100, 36.0, at: 1000)
        h.indicate(99, 36.1, at: 1000.15)
        #expect(h.readings.isEmpty && h.live.isEmpty)
        h.poll(record(ts: 100, profile: 1))
        #expect(h.readings.map(\.profile) == [1])
    }

    @Test func correctsTimestampByClockOffset() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 1_793_119_759, profile: 2))
        h.indicate(1_793_119_759, 35.6, at: 1000)
        #expect(h.readings.first?.measuredAt == Date(timeIntervalSince1970: 1_793_119_759 + offset))
    }

    @Test func missedRecordInBatchIsAmbiguous() {
        var h = Harness(offset: offset)
        for (i, ts) in [UInt32(100), 99, 98].enumerated() {
            h.indicate(ts, 36.0 + Double(i) / 10, at: 1000 + Double(i) * 0.15)
        }
        h.poll(record(ts: 100, profile: 1))
        h.poll(record(ts: 98, profile: 2))
        #expect(h.readings.map(\.profile) == [1, 2])
        h.drain()
        #expect(h.readings.map(\.profile) == [1, 2, nil])
        #expect(h.live.isEmpty)
    }

    @Test func loneLiveIndicationReadsCurrentProfile() {
        var h = Harness(offset: offset)
        h.drain()
        h.indicate(500, 36.7, at: 2000)
        #expect(h.readings.isEmpty)
        #expect(h.live == [TemperatureMeasurement(celsius: 36.7, timestamp: 500)])
        let reading = h.attributor.completeLive(h.live[0], profile: 1)
        #expect(reading?.profile == 1)
        #expect(reading?.measuredAt == Date(timeIntervalSince1970: 500 + offset))
    }

    @Test func loneIndicationUnmatchedWhenPollingFinishesReadsCurrentProfile() {
        var h = Harness(offset: offset)
        h.indicate(500, 36.7, at: 2000)
        h.drain()
        #expect(h.live.count == 1 && h.readings.isEmpty)
    }

    @Test func liveIndicationAfterQuietPeriodIsLoneAgain() {
        var h = Harness(offset: offset)
        h.drain()
        h.indicate(500, 36.7, at: 2000)
        h.indicate(560, 36.8, at: 2060)
        #expect(h.live.count == 2)
    }

    @Test func liveIndicationsWithinWindowAreAmbiguous() {
        var h = Harness(offset: offset)
        h.drain()
        h.indicate(500, 36.7, at: 2000)
        h.indicate(499, 36.6, at: 2000.5)
        #expect(h.live.count == 1)
        #expect(h.readings.map(\.profile) == [nil])
    }

    @Test func lateOrDuplicateRecordsAreIgnored() {
        var h = Harness(offset: offset)
        h.indicate(100, 36.0, at: 1000)
        h.poll(record(ts: 100, profile: 1))
        h.poll(record(ts: 100, profile: 2))
        h.drain()
        h.poll(record(ts: 100, profile: 2))
        #expect(h.readings.map(\.profile) == [1])
    }

    @Test func filtersNonBodyTemperatures() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 2))
        h.poll(record(ts: 101, profile: 2))
        h.poll(record(ts: 102, profile: 2))
        h.indicate(100, 26.8, at: 1000)
        h.indicate(101, 31.9, at: 1000.1)
        h.indicate(102, 43.1, at: 1000.2)
        h.drain()
        #expect(h.readings.isEmpty && h.live.isEmpty)
    }

    @Test func filteredIndicationCountsTowardBatch() {
        var h = Harness(offset: offset)
        h.indicate(100, 26.8, at: 1000)
        h.indicate(99, 36.0, at: 1000.15)
        h.drain()
        #expect(h.readings.map(\.profile) == [nil])
        #expect(h.live.isEmpty)
    }

    @Test func boundariesAreInclusive() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.poll(record(ts: 101, profile: 1))
        h.indicate(100, 32.0, at: 1000)
        h.indicate(101, 43.0, at: 1000.1)
        #expect(h.readings.map(\.celsius) == [32.0, 43.0])
    }

    @Test func dedupesRepeatedReading() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.indicate(100, 36.5, at: 1000)
        h.indicate(100, 36.5, at: 1000.2)
        #expect(h.readings.count == 1)
    }

    @Test func dedupesAcrossSessions() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.indicate(100, 36.5, at: 1000)
        h.attributor.beginSession(clockOffset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.indicate(100, 36.5, at: 5000)
        #expect(h.readings.count == 1)
    }

    @Test func differentProfilesAtSameSecondAreDistinct() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.indicate(100, 36.5, at: 1000)
        h.attributor.beginSession(clockOffset: offset)
        h.poll(record(ts: 100, profile: 2))
        h.indicate(100, 36.5, at: 5000)
        #expect(h.readings.map(\.profile) == [1, 2])
    }

    @Test func pollingStopsAfterThreeConsecutiveEmptyReads() {
        var h = Harness(offset: offset)
        h.poll(.empty)
        h.poll(.empty)
        h.poll(record(ts: 1, profile: 1))
        h.poll(.empty)
        h.poll(.empty)
        #expect(h.keepPolling)
        h.poll(.empty)
        #expect(!h.keepPolling)
    }

    @Test func finishingPollingEarlyFinalisesPendingIndications() {
        var h = Harness(offset: offset)
        h.indicate(100, 36.0, at: 1000)
        h.indicate(99, 36.1, at: 1000.15)
        h.indicate(50, 36.2, at: 1010)
        h.poll(record(ts: 100, profile: 1))
        h.apply(h.attributor.finishPolling())
        #expect(h.readings.map(\.profile) == [1, nil])
        #expect(h.live == [TemperatureMeasurement(celsius: 36.2, timestamp: 50)])
    }

    @Test func newSessionDiscardsRecords() {
        var h = Harness(offset: offset)
        h.poll(record(ts: 100, profile: 1))
        h.attributor.beginSession(clockOffset: offset)
        h.drain()
        h.indicate(100, 36.5, at: 1000)
        #expect(h.live.count == 1)
    }
}
