import Foundation
import Observation

@MainActor @Observable
final class ReadingsModel {
    private(set) var state: ConnectionState = .waiting
    private(set) var readings: [ThermometerReading] = []
    private(set) var logLines: [String] = []

    private static let maxLogLines = 300
    private let client: ThermometerClient

    init(client: ThermometerClient) {
        self.client = client
        let events = client.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        client.start()
    }

    /// Removes `reading` from the list. App-only: nothing is written to the thermometer.
    func delete(_ reading: ThermometerReading) {
        readings.removeAll { $0.id == reading.id }
    }

    func handle(_ event: ThermometerEvent) {
        switch event {
        case .state(let state):
            self.state = state
        case .reading(let reading):
            readings.append(reading)
            readings.sort { $0.measuredAt > $1.measuredAt }
        case .log(let line):
            logLines.append("\(Date.now.formatted(date: .omitted, time: .standard)) \(line)")
            if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
        }
    }
}
