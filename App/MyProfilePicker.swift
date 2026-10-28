import SwiftUI

struct MyProfilePicker: View {
    @Bindable var health: HealthSync

    var body: some View {
        Picker("My profile", selection: $health.myProfile) {
            Text("Not set").tag(Int?.none)
            ForEach(0..<3, id: \.self) { Text("Profile \($0)").tag(Int?.some($0)) }
        }
    }
}
