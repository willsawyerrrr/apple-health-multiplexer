import SwiftUI

@main
struct KintempApp: App {
    @State private var model = ReadingsModel(client: CoreThermometerClient())

    var body: some Scene {
        WindowGroup {
            ReadingsView(model: model)
        }
    }
}
