import Foundation

/// A 2A75 queue record.
struct ThermometerRecord: Equatable {
    /// Measurement time on the thermometer clock, as Unix seconds.
    var timestamp: UInt32
    var index: UInt16
    var profile: UInt16
}

/// The result of reading 2A75.
enum QueueRead: Equatable {
    case empty
    case record(ThermometerRecord)

    /// Parses a 20-byte 2A75 value; all zero bytes mean the queue is empty.
    /// Returns `nil` for any other length.
    init?(_ data: Data) {
        guard data.count == 20 else { return nil }
        if data.allSatisfy({ $0 == 0 }) {
            self = .empty
        } else {
            self = .record(
                ThermometerRecord(
                    timestamp: data.uint32BE(at: 0),
                    index: data.uint16BE(at: 4),
                    profile: data.uint16BE(at: 16)
                ))
        }
    }
}
