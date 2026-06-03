import Foundation

/// Thin async REST client for the Trakt.tv API (https://api.trakt.tv).
///
/// Pure Swift (URLSession + Codable) — Trakt is a normal REST service, so unlike HDRezka
/// scraping this does NOT go through the Python sidecar. The user supplies their own free
/// Trakt API app credentials (client id + secret) in Settings; nothing is hardcoded.
///
/// Auth uses Trakt's OAuth **device** flow (no redirect URI / embedded browser needed):
///   1. POST /oauth/device/code → user_code + verification_url shown to the user.
///   2. Poll POST /oauth/device/token until the user authorizes in their browser.
/// Tokens are persisted in the macOS Keychain (account "trakt-tokens") and refreshed on demand.
///
/// All "write" helpers (markWatched / addToWatchlist) are best-effort: if Trakt isn't connected
/// or the title can't be matched, they no-op rather than throwing into the UI.
actor TraktClient {
    static let base = URL(string: "https://api.trakt.tv")!
    static let tokensAccount = Keychain.traktTokensAccount

    private let clientIDProvider: () -> String
    private let clientSecretProvider: () -> String

    private var tokens: Tokens?

    init(clientIDProvider: @escaping () -> String,
         clientSecretProvider: @escaping () -> String) {
        self.clientIDProvider = clientIDProvider
        self.clientSecretProvider = clientSecretProvider
        self.tokens = Self.loadTokens()
    }

    // MARK: - Token model + persistence

    struct Tokens: Codable {
        var access: String
        var refresh: String
        /// Absolute expiry (Unix seconds).
        var expiresAt: Double

        var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt - 60 }
    }

    /// Whether we currently hold tokens (does not validate them against the server).
    var hasTokens: Bool { tokens != nil }

    private static func loadTokens() -> Tokens? {
        guard let json = Keychain.load(account: tokensAccount),
              let data = json.data(using: .utf8),
              let t = try? JSONDecoder().decode(Tokens.self, from: data) else { return nil }
        return t
    }

    private func persist(_ tokens: Tokens?) {
        self.tokens = tokens
        guard let tokens else { Keychain.delete(account: Self.tokensAccount); return }
        if let data = try? JSONEncoder().encode(tokens),
           let json = String(data: data, encoding: .utf8) {
            Keychain.save(json, account: Self.tokensAccount)
        }
    }

    /// Forget the stored tokens (used on Disconnect).
    func clearTokens() { persist(nil) }

    // MARK: - OAuth device flow

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let created_at: Double
        let expires_in: Double
    }

    enum TraktError: Error {
        case notConfigured
        case http(Int)
        case denied
        case expired
        case transport(String)
    }

    /// Begin the device flow. Returns the code/URL the UI should show the user.
    func requestDeviceCode() async throws -> DeviceCode {
        let clientID = clientIDProvider()
        guard !clientID.isEmpty else { throw TraktError.notConfigured }
        var req = URLRequest(url: Self.base.appendingPathComponent("oauth/device/code"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])
        let (data, resp) = try await send(req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw TraktError.http(code) }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Poll for the access token until the user authorizes (or the code expires / is denied).
    /// Honours the server-provided `interval`, backing off on HTTP 429 ("slow down").
    /// On success the tokens are persisted; throws on terminal failures.
    func pollForToken(_ device: DeviceCode) async throws {
        let clientID = clientIDProvider()
        let clientSecret = clientSecretProvider()
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw TraktError.notConfigured }

        var interval = max(1, device.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expires_in))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var req = URLRequest(url: Self.base.appendingPathComponent("oauth/device/token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": device.device_code,
                "client_id": clientID,
                "client_secret": clientSecret,
            ])
            let (data, resp) = try await send(req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                let t = try JSONDecoder().decode(TokenResponse.self, from: data)
                persist(Tokens(access: t.access_token, refresh: t.refresh_token,
                               expiresAt: t.created_at + t.expires_in))
                return
            case 400:
                continue              // pending — user hasn't authorized yet, keep polling
            case 409:
                return                // already used: treat as success (token already issued)
            case 410:
                throw TraktError.expired      // the device code expired
            case 418:
                throw TraktError.denied       // the user denied the request
            case 429:
                interval += 1                 // slow down
                continue
            case let other:
                throw TraktError.http(other)
            }
        }
        throw TraktError.expired
    }

    // MARK: - Token refresh + authed requests

    /// Return a valid access token, refreshing if expired. Throws if not connected.
    private func validAccessToken() async throws -> String {
        guard var t = tokens else { throw TraktError.notConfigured }
        if t.isExpired { t = try await refresh(t) }
        return t.access
    }

    private func refresh(_ old: Tokens) async throws -> Tokens {
        let clientID = clientIDProvider()
        let clientSecret = clientSecretProvider()
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw TraktError.notConfigured }
        var req = URLRequest(url: Self.base.appendingPathComponent("oauth/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": old.refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ])
        let (data, resp) = try await send(req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            // Refresh failed (revoked / invalid) — drop the dead tokens.
            persist(nil)
            throw TraktError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        let fresh = Tokens(access: r.access_token, refresh: r.refresh_token,
                           expiresAt: r.created_at + r.expires_in)
        persist(fresh)
        return fresh
    }

    /// Build an authenticated request with the standard Trakt headers.
    private func authedRequest(_ path: String, method: String,
                               body: [String: Any]? = nil) async throws -> URLRequest {
        let access = try await validAccessToken()
        let clientID = clientIDProvider()
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    // MARK: - User identity

    private struct User: Decodable { let username: String? }

    /// The connected account's username (for the "Connected as …" label). nil if not connected.
    func username() async -> String? {
        guard tokens != nil else { return nil }
        do {
            let req = try await authedRequest("users/me", method: "GET")
            let (data, resp) = try await send(req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(User.self, from: data).username
        } catch {
            return nil
        }
    }

    // MARK: - Search

    private struct SearchHit: Decodable {
        let movie: MediaRef?
        let show: MediaRef?
    }
    private struct MediaRef: Decodable {
        let ids: IDs
    }
    private struct IDs: Decodable {
        let trakt: Int
    }

    /// Find the Trakt id of the top movie/show matching `query` (optionally filtered by year).
    private func searchTraktID(query: String, year: Int?, isSeries: Bool) async -> Int? {
        let type = isSeries ? "show" : "movie"
        var comps = URLComponents(url: Self.base.appendingPathComponent("search/\(type)"),
                                  resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "query", value: query)]
        if let year { items.append(URLQueryItem(name: "years", value: String(year))) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        do {
            let clientID = clientIDProvider()
            let access = try await validAccessToken()
            var req = URLRequest(url: url)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("2", forHTTPHeaderField: "trakt-api-version")
            req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, resp) = try await send(req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let hits = try JSONDecoder().decode([SearchHit].self, from: data)
            return hits.first.flatMap { isSeries ? $0.show?.ids.trakt : $0.movie?.ids.trakt }
        } catch {
            return nil
        }
    }

    /// Resolve a Trakt id, preferring the original (non-localized) title for the query and
    /// falling back to the display title if the original yields no match.
    private func resolveID(originalTitle: String?, title: String,
                           year: Int?, isSeries: Bool) async -> Int? {
        if let orig = originalTitle?.trimmingCharacters(in: .whitespaces), !orig.isEmpty {
            if let id = await searchTraktID(query: orig, year: year, isSeries: isSeries) {
                return id
            }
        }
        return await searchTraktID(query: title, year: year, isSeries: isSeries)
    }

    // MARK: - Sync writes (best-effort, never throw to the UI)

    /// Mark a movie or a specific episode as watched in the user's Trakt history.
    func markWatched(originalTitle: String?, title: String, year: Int?,
                     isSeries: Bool, season: Int?, episode: Int?) async {
        guard tokens != nil else { return }
        guard let id = await resolveID(originalTitle: originalTitle, title: title,
                                       year: year, isSeries: isSeries) else { return }
        let body: [String: Any]
        if isSeries {
            // Need a concrete season+episode to log a series view.
            guard let season, let episode else { return }
            body = ["shows": [[
                "ids": ["trakt": id],
                "seasons": [[
                    "number": season,
                    "episodes": [["number": episode]],
                ]],
            ]]]
        } else {
            body = ["movies": [["ids": ["trakt": id]]]]
        }
        await postSync("sync/history", body: body)
    }

    /// Add a movie or show to the user's Trakt watchlist.
    func addToWatchlist(originalTitle: String?, title: String, year: Int?, isSeries: Bool) async {
        guard tokens != nil else { return }
        guard let id = await resolveID(originalTitle: originalTitle, title: title,
                                       year: year, isSeries: isSeries) else { return }
        let key = isSeries ? "shows" : "movies"
        let body: [String: Any] = [key: [["ids": ["trakt": id]]]]
        await postSync("sync/watchlist", body: body)
    }

    private func postSync(_ path: String, body: [String: Any]) async {
        do {
            let req = try await authedRequest(path, method: "POST", body: body)
            _ = try await send(req)
        } catch {
            // Best-effort: swallow.
        }
    }

    // MARK: - Plumbing

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw TraktError.transport(error.localizedDescription)
        }
    }
}
