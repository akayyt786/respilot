import SwiftUI

@main
struct ResPilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ResPilot", id: "main") {
            MainWindowView(model: model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("ResPilot", systemImage: "rectangle.arrowtriangle.2.outward") {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
