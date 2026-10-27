import Foundation
import Testing

@testable import AppleHealthMultiplexer

struct ReadingAttributorTests {
    private let offset: TimeInterval = 123

    private func session() -> ReadingAttributor {
        var attributor = ReadingAttributor()
        attributor.beginSession(clockOffset: offset)
        return attributor
    }

    private func measurement(_ ts: UInt32, _ celsius: Double) -> TemperatureMeasurement {
        TemperatureMeasurement(celsius: celsius, timestamp: ts)
    }

    @Test func attributesRealBatchByTimestamp() {
        var attributor = session()
        for fixture in fixtures { _ = attributor.observe(record(ts: fixture.ts, profile: fixture.profile)) }
        var readings: [ThermometerReading] = []
        for (i, fixture) in fixtures.enumerated() {
            let outcome = attributor.receive(measurement(fixture.ts, fixture.celsius), at: 1000 + Double(i) * 0.15)
            guard case .resolved(let reading) = outcome else { Issue.record("unexpected \(outcome)"); return }
            if let reading { readings.append(reading) }
        }
        #expect(readings.map(\.profile) == [2, 1, 2, 1, 1, 2])
        #expect(readings.map(\.celsius) == [35.6, 36.0, 35.9, 36.2, 36.4, 36.1])
        #expect(readings.allSatisfy { !$0.isAmbiguous })
    }

    @Test func correctsTimestampByClockOffset() {
        var attributor = session()
        _ = attributor.observe(record(ts: 1_793_119_759, profile: 2))
        let outcome = attributor.receive(measurement(1_793_119_759, 35.6), at: 1000)
        guard case .resolved(let reading?) = outcome else { Issue.record("no reading"); return }
        #expect(reading.measuredAt == Date(timeIntervalSince1970: 1_793_119_759 + offset))
    }

    @Test func missedRecordInBatchIsAmbiguous() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        _ = attributor.observe(record(ts: 98, profile: 2))
        var profiles: [Int?] = []
        for (i, ts) in [UInt32(100), 99, 98].enumerated() {
            let outcome = attributor.receive(measurement(ts, 36.0 + Double(i) / 10), at: 1000 + Double(i) * 0.15)
            guard case .resolved(let reading?) = outcome else { Issue.record("no reading"); return }
            profiles.append(reading.profile)
        }
        #expect(profiles == [1, nil, 2])
    }

    @Test func loneLiveIndicationReadsCurrentProfile() {
        var attributor = session()
        for _ in 0..<3 { _ = attributor.observe(.empty) }
        let m = measurement(500, 36.7)
        let r1 = attributor.receive(m, at: 2000)
        #expect(r1 == .needsCurrentProfile)
        let reading = attributor.completeLive(m, profile: 1)
        #expect(reading?.profile == 1)
        #expect(reading?.measuredAt == Date(timeIntervalSince1970: 500 + offset))
    }

    @Test func indicationAfterQuietPeriodIsLiveAgain() {
        var attributor = session()
        let r2 = attributor.receive(measurement(500, 36.7), at: 2000)
        #expect(r2 == .needsCurrentProfile)
        let r3 = attributor.receive(measurement(560, 36.8), at: 2060)
        #expect(r3 == .needsCurrentProfile)
    }

    @Test func indicationWithinWindowOfAnotherIsNotLive() {
        var attributor = session()
        let r4 = attributor.receive(measurement(500, 36.7), at: 2000)
        #expect(r4 == .needsCurrentProfile)
        guard case .resolved(let reading?) = attributor.receive(measurement(499, 36.6), at: 2000.5) else {
            Issue.record("expected ambiguous reading")
            return
        }
        #expect(reading.isAmbiguous)
    }

    @Test func filtersNonBodyTemperatures() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 2))
        let r5 = attributor.receive(measurement(100, 26.8), at: 1000)
        #expect(r5 == .resolved(nil))
        let r6 = attributor.receive(measurement(101, 31.9), at: 1500)
        #expect(r6 == .resolved(nil))
        let r7 = attributor.receive(measurement(102, 43.1), at: 1500.1)
        #expect(r7 == .resolved(nil))
    }

    @Test func filteredIndicationCountsTowardBatch() {
        var attributor = session()
        let r8 = attributor.receive(measurement(100, 26.8), at: 1000)
        #expect(r8 == .resolved(nil))
        guard case .resolved(let reading?) = attributor.receive(measurement(99, 36.0), at: 1000.15) else {
            Issue.record("expected ambiguous reading")
            return
        }
        #expect(reading.isAmbiguous)
    }

    @Test func boundariesAreInclusive() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        _ = attributor.observe(record(ts: 101, profile: 1))
        guard case .resolved(let low?) = attributor.receive(measurement(100, 32.0), at: 1000),
            case .resolved(let high?) = attributor.receive(measurement(101, 43.0), at: 1000.1)
        else { Issue.record("filtered"); return }
        #expect(low.celsius == 32.0 && high.celsius == 43.0)
    }

    @Test func dedupesRepeatedReading() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        guard case .resolved(let first) = attributor.receive(measurement(100, 36.5), at: 1000) else { return }
        #expect(first != nil)
        let r9 = attributor.receive(measurement(100, 36.5), at: 1000.2)
        #expect(r9 == .resolved(nil))
    }

    @Test func dedupesAcrossSessions() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        _ = attributor.receive(measurement(100, 36.5), at: 1000)
        attributor.beginSession(clockOffset: offset)
        _ = attributor.observe(record(ts: 100, profile: 1))
        let r10 = attributor.receive(measurement(100, 36.5), at: 5000)
        #expect(r10 == .resolved(nil))
    }

    @Test func differentProfilesAtSameSecondAreDistinct() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        guard case .resolved(let a?) = attributor.receive(measurement(100, 36.5), at: 1000) else { return }
        attributor.beginSession(clockOffset: offset)
        _ = attributor.observe(record(ts: 100, profile: 2))
        guard case .resolved(let b?) = attributor.receive(measurement(100, 36.5), at: 5000) else {
            Issue.record("deduped across profiles")
            return
        }
        #expect(a.profile == 1 && b.profile == 2)
    }

    @Test func pollingStopsAfterThreeConsecutiveEmptyReads() {
        var attributor = session()
        let r11 = attributor.observe(.empty)
        #expect(r11)
        let r12 = attributor.observe(.empty)
        #expect(r12)
        let r13 = attributor.observe(record(ts: 1, profile: 1))
        #expect(r13)
        let r14 = attributor.observe(.empty)
        #expect(r14)
        let r15 = attributor.observe(.empty)
        #expect(r15)
        let r16 = attributor.observe(.empty)
        #expect(!r16)
    }

    @Test func newSessionDiscardsRecords() {
        var attributor = session()
        _ = attributor.observe(record(ts: 100, profile: 1))
        attributor.beginSession(clockOffset: offset)
        let r17 = attributor.receive(measurement(100, 36.5), at: 1000)
        #expect(r17 == .needsCurrentProfile)
    }
}
