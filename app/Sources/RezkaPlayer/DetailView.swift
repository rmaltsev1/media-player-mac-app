import SwiftUI

struct DetailView: View {
    let item: CatalogueItem
    @EnvironmentObject var state: AppState

    @State private var info: TitleInfo?
    @State private var loading = true
    @State private var loadError: String?

    // Selection
    @State private var translatorID: Int?
    @State private var seasonID: Int?
    @State private var episodeID: Int?

    // Stream
    @State private var stream: StreamResponse?
    @State private var quality: String?
    @State private var streamLoading = false
    @State private var streamError: String?
    @State private var streamRequestID = 0   // guards against out-of-order refetches

    // Season download
    @State private var seasonDownloading = false
    @State private var seasonDone = 0
    @State private var seasonTotal = 0

    var body: some View {
        ScrollView {
            if loading {
                CenteredMessage(systemImage: "hourglass", title: "Loading…").frame(minHeight: 400)
            } else if let loadError {
                CenteredMessage(systemImage: "exclamationmark.triangle",
                                title: "Couldn't load title", subtitle: loadError).frame(minHeight: 400)
            } else if let info {
                content(info)
            }
        }
        .navigationTitle(info?.name ?? item.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let saved = state.bookmarks.isBookmarked(item)
                Button { state.bookmarks.toggle(item) } label: {
                    Label(saved ? "In Watch Later" : "Watch Later",
                          systemImage: saved ? "star.fill" : "star")
                }
                .help(saved ? "Remove from Watch Later" : "Add to Watch Later")
            }
        }
        .task { await loadInfo() }
    }

    // MARK: Header + body

    @ViewBuilder private func content(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                PosterImage(urlString: info.thumbnail ?? item.image)
                    .frame(width: 220, height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    Text(info.name).font(.title).bold()
                    if let orig = info.origName, orig != info.name {
                        Text(orig).font(.title3).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let y = info.releaseYear { Badge(text: String(y), system: "calendar") }
                        if let r = info.rating { Badge(text: String(format: "%.2f", r.value), system: "star.fill") }
                        if let c = info.category?.name { Badge(text: c.capitalized, system: "tag") }
                        Badge(text: info.isSeries ? "Series" : "Movie",
                              system: info.isSeries ? "tv" : "film")
                    }
                    if let desc = info.description {
                        Text(desc).font(.body).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    Spacer()
                }
                Spacer(minLength: 0)
            }

            Divider()
            playbackSection(info)
        }
        .padding(24)
    }

    // MARK: Playback controls

    @ViewBuilder private func playbackSection(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if info.isSeries { seasonEpisodePickers(info) }
            translatorPicker(info)

            if streamLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Fetching stream…") }
                    .foregroundStyle(.secondary)
            } else if let streamError {
                Label(streamError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            } else if let stream, !stream.videos.isEmpty {
                resolutionControls(stream, info: info)
            }
        }
    }

    @ViewBuilder private func seasonEpisodePickers(_ info: TitleInfo) -> some View {
        let seasons = info.episodes ?? []
        HStack(spacing: 16) {
            Picker("Season", selection: Binding(
                get: { seasonID ?? seasons.first?.season ?? 1 },
                set: { seasonID = $0; episodeID = nil; Task { await refetch() } })
            ) {
                ForEach(seasons) { s in Text(s.season_text).tag(s.season) }
            }.fixedSize()

            let eps = seasons.first { $0.season == (seasonID ?? seasons.first?.season) }?.episodes ?? []
            Picker("Episode", selection: Binding(
                get: { episodeID ?? eps.first?.episode ?? 1 },
                set: { episodeID = $0; Task { await refetch() } })
            ) {
                ForEach(eps) { e in Text(e.episode_text).tag(e.episode) }
            }.fixedSize()
        }
    }

    @ViewBuilder private func translatorPicker(_ info: TitleInfo) -> some View {
        let translators = availableTranslators(info)
        if !translators.isEmpty {
            Picker("Translation", selection: Binding(
                get: { translatorID ?? translators.first?.id },
                set: { translatorID = $0; Task { await refetch() } })
            ) {
                ForEach(translators) { t in
                    Text(t.premium ? "\(t.name) ★" : t.name).tag(Optional(t.id))
                }
            }
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder private func resolutionControls(_ stream: StreamResponse, info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Resolution", selection: Binding(
                get: { quality ?? stream.sortedQualities.last ?? "" },
                set: { quality = $0 })
            ) {
                ForEach(stream.sortedQualities, id: \.self) { q in Text(q).tag(q) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            HStack(spacing: 12) {
                if let target = playerTarget(stream) {
                    NavigationLink(value: target) {
                        Label("Play", systemImage: "play.fill").frame(width: 120)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    download(stream, info: info)
                } label: {
                    Label(info.isSeries ? "Download Episode" : "Download",
                          systemImage: "arrow.down.circle").frame(width: 150)
                }
                .buttonStyle(.bordered)

                if info.isSeries {
                    Button {
                        Task { await downloadSeason(info, like: stream) }
                    } label: {
                        Label("Download Season", systemImage: "square.and.arrow.down.on.square")
                            .frame(width: 160)
                    }
                    .buttonStyle(.bordered)
                    .disabled(seasonDownloading)
                }

                if let q = quality ?? stream.sortedQualities.last,
                   let n = stream.videos[q]?.count, n > 1 {
                    Text("\(n) mirrors").font(.caption).foregroundStyle(.secondary)
                }
            }
            if seasonDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Queuing season… \(seasonDone)/\(seasonTotal)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !stream.subtitles.isEmpty {
                Text("Subtitles available: \(stream.subtitles.map(\.title).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived

    private func availableTranslators(_ info: TitleInfo) -> [Translator] {
        guard info.isSeries else { return info.translators }
        let seasons = info.episodes ?? []
        let sid = seasonID ?? seasons.first?.season
        let eps = seasons.first { $0.season == sid }?.episodes ?? []
        let eid = episodeID ?? eps.first?.episode
        let trans = eps.first { $0.episode == eid }?.translations ?? []
        // Map episode translations into Translator, de-duped, preserving order.
        var seen = Set<Int>()
        return trans.compactMap { t in
            guard !seen.contains(t.translator_id) else { return nil }
            seen.insert(t.translator_id)
            return Translator(id: t.translator_id, name: t.translator_name, premium: t.premium)
        }
    }

    private func currentQuality(_ stream: StreamResponse) -> String? {
        quality ?? stream.sortedQualities.last
    }

    private func playerTarget(_ stream: StreamResponse) -> PlayerTarget? {
        guard let q = currentQuality(stream), let url = stream.url(for: q) else { return nil }
        return PlayerTarget(title: titleForPlayback(), urlString: url, isLocal: false,
                            subtitleURL: stream.subtitles.first?.link)
    }

    private func titleForPlayback() -> String {
        var t = info?.name ?? item.title
        if info?.isSeries == true, let s = seasonID, let e = episodeID { t += " · S\(s)E\(e)" }
        return t
    }

    private var seasonEpisodeTag: String? {
        guard info?.isSeries == true, let s = seasonID, let e = episodeID else { return nil }
        return "S\(s)E\(e)"
    }

    // MARK: Actions

    private func loadInfo() async {
        guard case .ready = state.sidecar.state else {
            loadError = "The helper isn't ready yet."; loading = false; return
        }
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let info = try await state.api.info(url: item.url)
            self.info = info
            translatorID = info.translators.first?.id
            if info.isSeries {
                seasonID = info.episodes?.first?.season
                episodeID = info.episodes?.first?.episodes.first?.episode
            }
            await refetch()
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refetch() async {
        guard let info, case .ready = state.sidecar.state else { return }

        // Resolve a consistent selection BEFORE requesting. When the season changes the episode
        // is reset to nil; default it to the season's first episode, and make sure the translator
        // is one that actually exists for that episode (otherwise the sidecar errors).
        var reqSeason: Int? = nil
        var reqEpisode: Int? = nil
        var reqTranslation = translatorID
        if info.isSeries {
            let seasons = info.episodes ?? []
            let sid = seasonID ?? seasons.first?.season
            let eps = seasons.first { $0.season == sid }?.episodes ?? []
            let eid = episodeID ?? eps.first?.episode
            let avail = eps.first { $0.episode == eid }?.translations ?? []
            var tid = translatorID
            if tid == nil || !avail.contains(where: { $0.translator_id == tid }) {
                tid = avail.first?.translator_id
            }
            seasonID = sid; episodeID = eid; translatorID = tid   // keep UI consistent
            reqSeason = sid; reqEpisode = eid; reqTranslation = tid
        }

        let myID = streamRequestID &+ 1
        streamRequestID = myID
        streamLoading = true; streamError = nil; stream = nil
        defer { if streamRequestID == myID { streamLoading = false } }
        do {
            let s = try await state.api.stream(url: item.url, translation: reqTranslation,
                                               season: reqSeason, episode: reqEpisode)
            guard streamRequestID == myID else { return }   // a newer request superseded us
            stream = s
            // Preserve the chosen resolution if it still exists, else pick the best.
            if let q = quality, s.videos[q] != nil { } else { quality = s.sortedQualities.last }
        } catch {
            guard streamRequestID == myID else { return }
            streamError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func download(_ stream: StreamResponse, info: TitleInfo) {
        guard let q = currentQuality(stream), let url = stream.url(for: q) else { return }
        state.downloads.startDownload(
            title: titleForPlayback(), pageURL: item.url, streamURL: url,
            quality: q, posterURL: info.thumbnail ?? item.image,
            seasonEpisode: seasonEpisodeTag,
            fetchURL: state.playbackURLString(for: url)   // relay when proxied, else direct
        )
    }

    /// Queue downloads for every episode in the current season, in the selected resolution
    /// (falling back to the best available per episode), skipping ones already downloaded.
    private func downloadSeason(_ info: TitleInfo, like stream: StreamResponse) async {
        guard info.isSeries, let sid = seasonID,
              let season = (info.episodes ?? []).first(where: { $0.season == sid })
        else { return }

        let desired = quality ?? stream.sortedQualities.last
        seasonDownloading = true; seasonDone = 0; seasonTotal = season.episodes.count
        defer { seasonDownloading = false }

        for ep in season.episodes {
            let seTag = "S\(sid)E\(ep.episode)"
            defer { seasonDone += 1 }

            if let dq = desired,
               state.downloads.isDownloaded(pageURL: item.url, quality: dq, seasonEpisode: seTag) {
                continue   // already have it at this quality
            }
            // Use the selected translator if this episode has it, else its first available.
            let tid = ep.translations.contains(where: { $0.translator_id == translatorID })
                ? translatorID : ep.translations.first?.translator_id
            do {
                let s = try await state.api.stream(url: item.url, translation: tid,
                                                   season: sid, episode: ep.episode)
                let q = (desired.flatMap { s.videos[$0] != nil ? $0 : nil }) ?? s.sortedQualities.last
                guard let q, let url = s.url(for: q) else { continue }
                state.downloads.startDownload(
                    title: "\(info.name) · \(seTag)", pageURL: item.url, streamURL: url,
                    quality: q, posterURL: info.thumbnail ?? item.image, seasonEpisode: seTag,
                    fetchURL: state.playbackURLString(for: url)
                )
            } catch {
                continue   // skip episodes that fail to resolve
            }
        }
    }
}

struct Badge: View {
    let text: String
    let system: String
    var body: some View {
        Label(text, systemImage: system)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }
}
