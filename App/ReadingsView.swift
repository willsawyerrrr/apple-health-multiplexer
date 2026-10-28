import CloudKit
import SwiftUI

struct ReadingsView: View {
    let model: ReadingsModel
    let profiles: ProfileBook
    var invitations: AppInvitations?
    @State private var showsProfiles = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") { Text(model.state.description) }
                Section("Apple Health") { MyProfilePicker(health: model.health, book: profiles) }
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
            .toolbar {
                if let invitations {
                    Button("Invite household", systemImage: "person.badge.plus") {
                        Task { await invitations.invite() }
                    }
                    .disabled(invitations.isPreparing)
                }
                Button("Profiles", systemImage: "person.2") { showsProfiles = true }
            }
            .sheet(item: sharePresentation) { presented in CloudSharingView(share: presented.share) }
            .alert(
                "Household", isPresented: errorPresented,
                actions: { Button("OK") { invitations?.errorMessage = nil } },
                message: { Text(invitations?.errorMessage ?? "") })
            .sheet(isPresented: $showsProfiles) {
                ProfilesView(book: profiles, observedSlots: model.readings.compactMap(\.profile))
            }
        }
    }
}

extension ReadingsView {
    private struct PresentedShare: Identifiable {
        let share: CKShare
        var id: CKRecord.ID { share.recordID }
    }

    private var sharePresentation: Binding<PresentedShare?> {
        Binding(
            get: { invitations?.presentedShare.map(PresentedShare.init) },
            set: { if $0 == nil { invitations?.presentedShare = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { invitations?.errorMessage != nil },
            set: { if !$0 { invitations?.errorMessage = nil } })
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
