import SwiftUI

struct ReadingsView: View {
    let model: ReadingsModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") { Text(model.state.description) }
                Section("Readings") {
                    if model.readings.isEmpty {
                        Text("No readings yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.readings) { reading in
                        ReadingRow(reading: reading)
                    }
                }
                Section {
                    DisclosureGroup("Debug log") {
                        ForEach(Array(model.logLines.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Thermometer")
        }
    }
}

private struct ReadingRow: View {
    let reading: ThermometerReading

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(reading.celsius.formatted(.number.precision(.fractionLength(1))) + " °C").font(.headline)
                Text(reading.measuredAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let profile = reading.profile {
                Text("Profile \(profile)")
            } else {
                Label("Ambiguous", systemImage: "questionmark.circle").foregroundStyle(.orange)
            }
        }
    }
}

extension ConnectionState {
    var description: String {
        switch self {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied"
        case .waiting: "Waiting for thermometer"
        case .connecting: "Connecting"
        case .connected: "Connected"
        }
    }
}
