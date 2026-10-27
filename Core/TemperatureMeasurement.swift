import Foundation

/// A parsed 2A1C Temperature Measurement indication.
struct TemperatureMeasurement: Equatable {
    var celsius: Double
    /// Measurement time on the thermometer clock, as Unix seconds in UTC.
    var timestamp: UInt32

    /// Parses a GATT Temperature Measurement packet. Returns `nil` when the
    /// packet is short, lacks a timestamp, or carries a non-numeric value.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        let flags = bytes[0]
        guard flags & 0b010 != 0 else { return nil }

        var mantissa = Int32(bytes[1]) | Int32(bytes[2]) << 8 | Int32(bytes[3]) << 16
        if mantissa & 0x80_0000 != 0 { mantissa |= ~0xFF_FFFF }
        // NaN, NRes, reserved, and the infinities.
        guard ![0x7F_FFFF, 0x7F_FFFE, -0x80_0000, -0x7F_FFFF, -0x7F_FFFE].contains(mantissa) else { return nil }
        let exponent = Int(Int8(bitPattern: bytes[4]))
        let scale = pow(10.0, Double(abs(exponent)))
        let value = exponent < 0 ? Double(mantissa) / scale : Double(mantissa) * scale
        celsius = flags & 0b001 != 0 ? (value - 32) * 5 / 9 : value

        var components = DateComponents()
        components.year = Int(bytes[5]) | Int(bytes[6]) << 8
        components.month = Int(bytes[7])
        components.day = Int(bytes[8])
        components.hour = Int(bytes[9])
        components.minute = Int(bytes[10])
        components.second = Int(bytes[11])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(components.month!), (1...31).contains(components.day!),
              components.hour! < 24, components.minute! < 60, components.second! < 60,
              let date = calendar.date(from: components)
        else { return nil }
        let unix = date.timeIntervalSince1970
        guard unix >= 0, unix <= Double(UInt32.max) else { return nil }
        timestamp = UInt32(unix)
    }

    init(celsius: Double, timestamp: UInt32) {
        self.celsius = celsius
        self.timestamp = timestamp
    }
}
