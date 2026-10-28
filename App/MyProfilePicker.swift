import SwiftUI

struct MyProfilePicker: View {
    @Bindable var health: HealthSync
    let book: ProfileBook

    var body: some View {
        Picker("My profile", selection: $health.myProfile) {
            Text("Not set").tag(Int?.none)
            ForEach(Profile.thermometerSlots, id: \.self) { Text(book.displayName(slot: $0)).tag(Int?.some($0)) }
        }
        if let problem = health.accessProblem {
            Text(problem).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
