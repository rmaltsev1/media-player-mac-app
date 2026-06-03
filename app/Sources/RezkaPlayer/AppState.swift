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

    /// Globally preferred playback resolution (e.g. "1080p"); "" == auto (best available).
    @AppStorage("preferredQuality") var preferredQuality: String = "" {
        didSet { objectWillChange.send() }
    }

    /// HDRezka session cookies (empty when logged out). Sent on every sidecar request
    /// so premium translations / higher resolutions are available.
    @Published var cookies: [String: String] = [:]
    /// Email of the currently logged-in account (empty when logged out).
    @AppStorage("hdrezkaEmail") var loggedInEmail: String = ""

    var isLoggedIn: Bool { !cookies.isEmpty }

    let sidecar = SidecarManager()
    let downloads = DownloadManager()
    let bookmarks = BookmarkStore()
    let progress = ProgressStore()
    let prefs = PreferenceStore()
    lazy var api = APIClient(sidecar: sidecar) { [weak self] in
        self?.origin ?? "https://hdrezka.ag"
    } cookiesProvider: { [weak self] in
        self?.cookies ?? [:]
    }

    private var cancellables = Set<AnyCancellable>()

    var proxyEnabled: Bool {
        !proxyURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        // Restore a previously saved HDRezka session from the keychain.
        if let json = Keychain.load(account: Keychain.cookiesAccount),
           let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = saved
        }

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
        progress.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        prefs.objectWillChange
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

    // MARK: HDRezka account

    /// Log in via the sidecar; on success persist the session cookies to the keychain
    /// so they flow on all subsequent requests. Throws on failure with a usable message.
    func login(email: String, password: String) async throws {
        let resp = try await api.login(origin: origin, email: email, password: password)
        guard resp.ok, let c = resp.cookies, !c.isEmpty else {
            throw APIError.server(resp.message ?? "Login failed", type: nil)
        }
        cookies = c
        loggedInEmail = email
        if let data = try? JSONEncoder().encode(c),
           let json = String(data: data, encoding: .utf8) {
            Keychain.save(json, account: Keychain.cookiesAccount)
        }
    }

    /// Clear the stored session (cookies + saved email).
    func logout() {
        cookies = [:]
        loggedInEmail = ""
        Keychain.delete(account: Keychain.cookiesAccount)
    }

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
