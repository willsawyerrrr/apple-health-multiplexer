import SwiftUI

/// Lists the profiles the thermometer cycles through for renaming, adding and removing.
struct ProfilesView: View {
    let book: ProfileBook
    let model: ReadingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAdd = false
    @State private var newName = ""
    @State private var slotToRemove: Int?

    private var slots: [Int] {
        model.visibleSlots ?? book.slots(observed: model.readings.compactMap(\.profile))
    }

    private var newSlot: Int? { model.slotForNewPerson(reserved: book.storedSlots) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(slots, id: \.self) { slot in
                        ProfileRow(book: book, slot: slot)
                            .deleteDisabled(slot == Profile.guestSlot || model.visibleSlots == nil)
                    }
                    .onDelete { offsets in slotToRemove = offsets.map { slots[$0] }.first }
                } footer: {
                    if model.visibleSlots == nil {
                        Text("Connect to the thermometer to add or remove people.")
                    } else if !model.pendingSlotEdits.isEmpty {
                        Text("Changes reach the thermometer the next time it connects.")
                    } else {
                        Text("Choose who a reading is for on the thermometer.")
                    }
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add Person", systemImage: "plus") {
                        newName = ""
                        showsAdd = true
                    }
                    .disabled(newSlot == nil)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Add Person", isPresented: $showsAdd) {
                TextField("Name", text: $newName)
                Button("Add") { add() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let newSlot { Text("Adds slot \(newSlot) to the thermometer's profiles.") }
            }
            .confirmationDialog(
                "Remove this person?", isPresented: removalPresented, titleVisibility: .visible,
                presenting: slotToRemove,
                actions: { slot in
                    Button("Remove from Thermometer", role: .destructive) { model.removeSlot(slot) }
                },
                message: { slot in
                    Text(
                        "\(book.displayName(slot: slot)) disappears from the thermometer's profiles. Their readings, name and Apple Health data are kept."
                    )
                })
        }
    }

    private func add() {
        guard let slot = newSlot else { return }
        book.rename(slot: slot, to: newName)
        model.addSlot(slot)
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { slotToRemove != nil }, set: { if !$0 { slotToRemove = nil } })
    }
}

private struct ProfileRow: View {
    let book: ProfileBook
    let slot: Int
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField(Profile.defaultName(slot: slot), text: $name)
                .onSubmit { book.rename(slot: slot, to: name) }
            if slot == Profile.guestSlot {
                Text("Guest readings stay on this phone and are never saved to Health.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { name = book.profile(slot: slot).name }
        .onChange(of: book.profile(slot: slot).name) { _, name in self.name = name }
        .onDisappear { book.rename(slot: slot, to: name) }
    }
}
