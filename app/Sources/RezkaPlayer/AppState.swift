import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @AppStorage("hdrezkaOrigin") var origin: String = "https://hdrezka.ag" {
        didSet { objectWillChange.send() }
    }

    let sidecar = SidecarManager()
    let downloads = DownloadManager()
    lazy var api = APIClient(sidecar: sidecar) { [weak self] in
        self?.origin ?? "https://hdrezka.ag"
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Re-publish sidecar state changes so views observing AppState refresh.
        sidecar.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        downloads.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Ensure the Python helper is torn down when the app quits normally.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.sidecar.stop() }
            .store(in: &cancellables)
    }

    func boot() { sidecar.start() }
}
