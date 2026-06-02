import Foundation

/// Thin async client over the local sidecar's JSON endpoints.
final class APIClient {
    private let sidecar: SidecarManager
    /// Returns the currently configured HDRezka mirror origin (e.g. https://hdrezka.ag).
    private let originProvider: @MainActor () -> String

    init(sidecar: SidecarManager, originProvider: @escaping @MainActor () -> String) {
        self.sidecar = sidecar
        self.originProvider = originProvider
    }

    // MARK: Endpoints

    func search(_ query: String, advanced: Bool = false, page: Int = 1) async throws -> [CatalogueItem] {
        let body: [String: Any] = ["query": query, "find_all": advanced, "page": page]
        let r: SearchResponse = try await post("/search", body)
        return r.results
    }

    func browse(collection: String, category: String, page: Int = 1) async throws -> [CatalogueItem] {
        let body: [String: Any] = ["collection": collection, "category": category, "page": page]
        let r: BrowseResponse = try await post("/browse", body)
        return r.results
    }

    func info(url: String) async throws -> TitleInfo {
        try await post("/info", ["url": url])
    }

    func stream(url: String, translation: Int? = nil, season: Int? = nil, episode: Int? = nil) async throws -> StreamResponse {
        var body: [String: Any] = ["url": url]
        if let translation { body["translation"] = translation }
        if let season { body["season"] = season }
        if let episode { body["episode"] = episode }
        return try await post("/stream", body)
    }

    // MARK: Plumbing

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        let (base, token, origin) = try await MainActor.run { () -> (URL, String, String) in
            guard let base = sidecar.baseURL else { throw APIError.notReady }
            return (base, sidecar.token, originProvider())
        }

        var payload = body
        payload["origin"] = origin

        var req = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 45

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw APIError.server(err.error, type: err.type)
            }
            throw APIError.server("HTTP \(code)", type: nil)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.transport("Bad response: \(error.localizedDescription)")
        }
    }
}
