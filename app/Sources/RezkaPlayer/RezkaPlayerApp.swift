import SwiftUI

@main
struct RezkaPlayerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { state.boot() }
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 520)
        }
    }
}
