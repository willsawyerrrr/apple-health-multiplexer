import SwiftUI

@main
struct AppleHealthMultiplexerApp: App {
    @State private var model = ReadingsModel(client: CoreThermometerClient())

    var body: some Scene {
        WindowGroup {
            ReadingsView(model: model)
        }
    }
}
