import Foundation
import Testing

@testable import AppleHealthMultiplexer

struct ParserTests {
    @Test func parsesCelsiusMeasurement() throws {
        let m = try #require(TemperatureMeasurement(Data(hex: "066D0100FFEA070A1B0E1D2B02")))
        #expect(m.celsius == 36.5)
        #expect(m.timestamp == 1_793_111_383)
    }

    @Test func parsesNonBodyMeasurement() throws {
        let m = try #require(TemperatureMeasurement(Data(hex: "06F30000FFEA070A1B0E191002")))
        #expect(m.celsius == 24.3)
    }

    @Test func convertsFahrenheit() throws {
        // 97.7 °F = 36.5 °C
        let m = try #require(TemperatureMeasurement(Data(hex: "07D10300FFEA070A1B0E1D2B02")))
        #expect(abs(m.celsius - 36.5) < 0.001)
    }

    @Test func parsesNegativeMantissaAndPositiveExponent() throws {
        let m = try #require(TemperatureMeasurement(Data(hex: "06FDFFFF01EA070A1B0E1D2B02")))
        #expect(m.celsius == -30)
    }

    @Test(arguments: [
        "066D0100FFEA070A1B0E1D",  // short
        "046D0100FFEA070A1B0E1D2B",  // no timestamp flag
        "06FFFF7F00EA070A1B0E1D2B02",  // NaN
        "066D0100FFEA070D1B0E1D2B02",  // month 13
        "066D0100FFEA070A1B1E1D2B02",  // hour 30
    ])
    func rejectsInvalidMeasurement(hex: String) {
        #expect(TemperatureMeasurement(Data(hex: hex)) == nil)
    }

    @Test func parsesRecord() {
        let read = QueueRead(Data(hex: "6AE0D60F000710790D68000089FF6CBC00020900"))
        #expect(read == .record(ThermometerRecord(timestamp: 1_793_119_759, index: 7, profile: 2)))
    }

    @Test func parsesEmptyRecord() {
        #expect(QueueRead(Data(count: 20)) == .empty)
    }

    @Test func rejectsWrongLengthRecord() {
        #expect(QueueRead(Data(count: 10)) == nil)
    }

    @Test func readsBigEndianIntegers() {
        let data = Data(hex: "6AE0D60F0007")
        #expect(data.uint32BE(at: 0) == 0x6AE0_D60F)
        #expect(data.uint16BE(at: 4) == 7)
    }
}

struct ReadingTests {
    @Test func profileZeroIsNotAmbiguous() {
        let reading = ThermometerReading(profile: 0, celsius: 36.1, measuredAt: .now)
        #expect(!reading.isAmbiguous)
        #expect(ThermometerReading(profile: nil, celsius: 36.1, measuredAt: .now).isAmbiguous)
    }
}
