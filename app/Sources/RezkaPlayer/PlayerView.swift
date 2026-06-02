import SwiftUI
import AVKit

struct PlayerView: View {
    let target: PlayerTarget
    @EnvironmentObject var state: AppState
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                CenteredMessage(systemImage: "play.slash", title: "Can't play this stream")
            }
        }
        .navigationTitle(target.title)
        .onAppear(perform: setup)
    }

    private func setup() {
        guard player == nil else { return }
        let item: AVPlayerItem
        if target.isLocal {
            item = AVPlayerItem(url: URL(fileURLWithPath: target.urlString))
        } else {
            // When a proxy is set this becomes a 127.0.0.1 relay URL so the video egresses
            // through the proxy; otherwise it's the CDN URL directly.
            let effective = state.playbackURLString(for: target.urlString)
            guard let url = URL(string: effective) else { return }
            // HDRezka CDN expects a browser-like User-Agent (harmless for the local relay).
            let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                           "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            item = AVPlayerItem(asset: asset)
        }
        let p = AVPlayer(playerItem: item)
        p.play()
        player = p
    }
}
