import SwiftUI
import Sparkle

/// Owns Sparkle's updater. The feed URL and EdDSA public key live in Info.plist
/// (`SUFeedURL` / `SUPublicEDKey`), so this just starts the standard updater and surfaces a
/// "Check for Updates…" action plus the toggle state the Settings screen binds to.
///
/// Updates are fetched from the project's public GitHub Releases (an `appcast.xml` asset served
/// from the stable `releases/latest/download/` URL) and verified against the embedded public key —
/// independent of Apple notarization, which this free ad-hoc build doesn't use.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so menu/buttons disable while a check is in flight.
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true → reads Info.plist config and begins scheduled checks immediately.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Whether Sparkle is configured to check on its own schedule (user-toggleable in Settings).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Manually check now — shows Sparkle's standard UI (found/up-to-date/error).
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// The "Check for Updates…" menu item (greys out while a check is already running).
struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterController
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
