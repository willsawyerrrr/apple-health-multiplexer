import SwiftUI

/// Lists the household's profiles for renaming.
struct ProfilesView: View {
    let book: ProfileBook
    let observedSlots: [Int]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(book.slots(observed: observedSlots), id: \.self) { slot in
                ProfileRow(book: book, slot: slot)
            }
            .navigationTitle("Profiles")
            .toolbar { Button("Done") { dismiss() } }
        }
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
        .onDisappear { book.rename(slot: slot, to: name) }
    }
}
