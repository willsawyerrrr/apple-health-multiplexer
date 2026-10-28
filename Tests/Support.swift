import Foundation

@testable import Kintemp

extension Data {
    init(hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            data.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}

/// Real readings captured from the thermometer: (clock timestamp, °C, profile).
let fixtures: [(ts: UInt32, celsius: Double, profile: Int)] = [
    (1_793_119_759, 35.6, 2),
    (1_793_119_752, 26.8, 2),
    (1_793_119_749, 36.0, 1),
    (1_793_119_743, 35.9, 2),
    (1_793_119_741, 36.2, 1),
    (1_793_119_737, 36.4, 1),
    (1_793_119_732, 36.1, 2),
]

func record(ts: UInt32, profile: Int, index: UInt16 = 1) -> QueueRead {
    .record(ThermometerRecord(timestamp: ts, index: index, profile: UInt16(profile)))
}
