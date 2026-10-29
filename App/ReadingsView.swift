import CloudKit
import SwiftUI

struct ReadingsView: View {
    let model: ReadingsModel
    let profiles: ProfileBook
    var invitations: AppInvitations?
    @State private var showsProfiles = false
    @State private var readingToDelete: ThermometerReading?

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
                        readingToDelete = offsets.map { model.readings[$0] }.first
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
                    if invitations.isPreparing {
                        ProgressView().accessibilityLabel("Preparing invitation")
                    } else {
                        Button("Invite household", systemImage: "person.badge.plus") {
                            Task { await invitations.invite() }
                        }
                    }
                }
                Button("Profiles", systemImage: "person.2") { showsProfiles = true }
            }
            .sheet(item: sharePresentation) { presented in
                CloudSharingView(share: presented.share) { invitations?.sharingFailed($0) }
            }
            .alert(
                "Household", isPresented: errorPresented,
                actions: {
                    if invitations?.canRetryInvite == true {
                        Button("Retry") { Task { await invitations?.invite() } }
                    }
                    Button(invitations?.canRetryInvite == true ? "Cancel" : "OK", role: .cancel) {
                        invitations?.errorMessage = nil
                    }
                },
                message: { Text(invitations?.errorMessage ?? "") })
            .confirmationDialog(
                "Delete this reading?", isPresented: deletionPresented, titleVisibility: .visible,
                presenting: readingToDelete,
                actions: { reading in
                    Button("Delete for Everyone", role: .destructive) { model.delete(reading) }
                },
                message: { _ in
                    Text("This deletes the reading for everyone in your household and from Apple Health. It can't be undone.")
                })
            .sheet(isPresented: $showsProfiles) {
                ProfilesView(book: profiles, model: model)
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

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { readingToDelete != nil },
            set: { if !$0 { readingToDelete = nil } })
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
