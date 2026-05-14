import SwiftUI

@main
struct ProxyHelperApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRunning ? "circle.fill" : "circle")
        }
        .menuBarExtraStyle(.menu)

        Window("设置", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}
