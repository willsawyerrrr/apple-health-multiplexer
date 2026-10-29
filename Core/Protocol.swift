import Foundation

/// GATT identifiers of the ThermoCare thermometer.
enum ThermoCare {
    static let advertisedName = "THERMOCARE"

    /// Builds a custom characteristic UUID on the device's vendor base.
    static func custom(_ short: String) -> String { "0000\(short)-0000-2000-4200-D3E2ADFBE7EF" }

    static let healthThermometerService = "1809"
    static let currentTimeService = "1805"

    /// Standard Temperature Measurement (indicate).
    static let temperatureMeasurement = "2A1C"
    /// Head-of-queue record (read).
    static let queueHead = custom("2A75")
    /// Current profile, `UInt16` big-endian (read).
    static let currentProfile = custom("2A78")
    /// Profile command (write): the enabled-slot mask.
    static let profileCommand = custom("2A74")
    /// Enabled-slot mask, 14 bytes (read).
    static let enabledSlots = custom("2A79")
    /// Thermometer clock, Unix seconds big-endian (read).
    static let clock = custom("2A2C")
}

extension Data {
    /// Big-endian `UInt16` at `offset`.
    func uint16BE(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) << 8 | UInt16(self[startIndex + offset + 1])
    }

    /// Big-endian `UInt32` at `offset`.
    func uint32BE(at offset: Int) -> UInt32 {
        UInt32(uint16BE(at: offset)) << 16 | UInt32(uint16BE(at: offset + 2))
    }

    var hex: String { map { String(format: "%02X", $0) }.joined() }
}
