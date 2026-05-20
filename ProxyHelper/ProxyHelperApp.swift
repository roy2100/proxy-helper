import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            KernelManager.shared.stopImmediately()
            SystemProxyManager.shared.disable()
        }
    }
}

@main
struct ProxyHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRunning ? "p.square.fill" : "p.square")
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)

        Window("mihomo 日志", id: "logs") {
            LogView()
                .environment(appState)
        }
        .windowResizability(.contentSize)

    }
}
