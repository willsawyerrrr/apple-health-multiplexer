import SwiftUI

struct ReadingsView: View {
    let model: ReadingsModel
    let profiles: ProfileBook
    @State private var showsProfiles = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") { Text(model.state.description) }
                Section("Readings") {
                    if model.readings.isEmpty {
                        Text("No readings yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.readings) { reading in
                        ReadingRow(reading: reading, profileName: profiles.displayName(slot: reading.profile))
                    }
                    .onDelete { offsets in
                        for reading in offsets.map({ model.readings[$0] }) { model.delete(reading) }
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
            .toolbar { Button("Profiles", systemImage: "person.2") { showsProfiles = true } }
            .sheet(isPresented: $showsProfiles) {
                ProfilesView(book: profiles, observedSlots: model.readings.compactMap(\.profile))
            }
        }
    }
}

private struct ReadingRow: View {
    let reading: ThermometerReading
    let profileName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(reading.celsius.formatted(.number.precision(.fractionLength(1))) + " °C").font(.headline)
                Text(reading.measuredAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if reading.profile != nil {
                Text(profileName)
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
