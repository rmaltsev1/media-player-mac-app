import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @AppStorage("hdrezkaOrigin") var origin: String = "https://hdrezka.ag" {
        didSet { objectWillChange.send() }
    }
    /// Optional proxy (e.g. "socks5://user:pass@host:1080"). When set, scraping AND video
    /// (playback + downloads, via the sidecar relay) egress through it.
    @AppStorage("proxyURL") var proxyURLString: String = "" {
        didSet { objectWillChange.send() }
    }

    let sidecar = SidecarManager()
    let downloads = DownloadManager()
    let bookmarks = BookmarkStore()
    lazy var api = APIClient(sidecar: sidecar) { [weak self] in
        self?.origin ?? "https://hdrezka.ag"
    }

    private var cancellables = Set<AnyCancellable>()

    var proxyEnabled: Bool {
        !proxyURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        // Re-publish sidecar state changes so views observing AppState refresh.
        sidecar.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        downloads.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Push the proxy config to the sidecar whenever it (re)starts and becomes ready.
        sidecar.$state
            .sink { [weak self] state in
                if case .ready = state { self?.pushProxyConfig() }
            }
            .store(in: &cancellables)

        // Ensure the Python helper is torn down when the app quits normally.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.sidecar.stop() }
            .store(in: &cancellables)
    }

    func boot() { sidecar.start() }

    /// Send the current proxy setting to the sidecar (applies to all its traffic + the relay).
    func pushProxyConfig() {
        let proxy = proxyURLString.trimmingCharacters(in: .whitespaces)
        Task { try? await api.configure(proxy: proxy) }
    }

    /// For a remote CDN URL, return the URL playback/downloads should actually hit:
    /// the local sidecar relay when a proxy is configured (so bytes egress via the proxy),
    /// otherwise the CDN URL directly.
    func playbackURLString(for cdnURL: String) -> String {
        guard proxyEnabled, let base = sidecar.baseURL else { return cdnURL }
        var comps = URLComponents(url: base.appendingPathComponent("relay"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "u", value: Self.b64url(cdnURL)),
            URLQueryItem(name: "t", value: sidecar.token),
            URLQueryItem(name: "r", value: Self.b64url(origin)),
        ]
        return comps.url!.absoluteString
    }

    /// URL-safe base64 without padding (matches the sidecar's `_b64url_decode`).
    static func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
