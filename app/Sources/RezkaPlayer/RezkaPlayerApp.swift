import SwiftUI
import AppKit

@main
struct RezkaPlayerApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(updater)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { state.boot() }
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { state.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(updater)
                .frame(width: 520)
        }

        MenuBarExtra("RezkaPlayer", systemImage: "play.rectangle.on.rectangle") {
            MenuBarContent()
                .environmentObject(state)
        }
    }
}

/// Lightweight menu-bar mini-controller: helper status, active downloads, and quick actions.
private struct MenuBarContent: View {
    @EnvironmentObject var state: AppState

    private var activeDownloads: [DownloadItem] {
        state.downloads.items.filter { $0.state == .downloading }
    }

    var body: some View {
        Text(helperStatus)
            .font(.caption)

        Divider()

        if activeDownloads.isEmpty {
            Text("No active downloads").foregroundStyle(.secondary)
        } else {
            ForEach(activeDownloads) { item in
                Text("\(item.title) — \(Int(item.progress * 100))%")
            }
        }

        Divider()

        Button("Open RezkaPlayer") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var helperStatus: String {
        switch state.sidecar.state {
        case .ready(let p): return "Helper ready · :\(p)"
        case .starting: return "Starting helper…"
        case .stopped: return "Helper stopped"
        case .failed(let m): return "Helper error: \(m)"
        }
    }
}
