# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

**RezkaPlayer** — a native macOS media player for browsing, streaming, and downloading from
HDRezka. Personal-use tool. Two parts:

- **`app/`** — SwiftUI macOS app (UI, AVKit player, downloads, library, menu-bar, notifications).
- **`sidecar/`** — a Python helper the app spawns on `127.0.0.1`; it does *all* HDRezka scraping.

The app talks to the sidecar over local HTTP (JSON). The scraping library
[SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi) is **vendored** under
`sidecar/hdrezka/` and maintained here (so we can patch when HDRezka changes).

## Build & run

```bash
# Sidecar (Python 3.9+). The app launches it automatically; this is just for manual testing.
cd sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # requests, beautifulsoup4, PySocks
python server.py --port 8777             # prints "SIDECAR_READY ... port=N"

# App (needs Xcode 26 + xcodegen: `brew install xcodegen`)
cd app
xcodegen generate                        # regenerates RezkaPlayer.xcodeproj from project.yml
xcodebuild -project RezkaPlayer.xcodeproj -scheme RezkaPlayer -configuration Debug \
  -destination 'platform=macOS' build
```

Built app: `~/Library/Developer/Xcode/DerivedData/RezkaPlayer-*/Build/Products/Debug/RezkaPlayer.app`.
Packaged DMG: `./scripts/package.sh` → `build/RezkaPlayer.dmg` (see Packaging below).

## Architecture & conventions

- **`app/project.yml` is the source of truth** for the Xcode project. The `.xcodeproj` is
  **gitignored and regenerated** — never hand-edit it; edit `project.yml` and run `xcodegen generate`.
  Version lives in `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (Info.plist references them).
- **Sidecar process management** (`Sidecar.swift`): the app prefers a **bundled** frozen sidecar
  (`Resources/sidecar/rezka-sidecar/rezka-sidecar`, present in packaged builds) and falls back to the
  dev venv/`server.py` otherwise. It launches with `--port 0` (OS-assigned), parses the
  `SIDECAR_READY host=.. port=N` stdout line, and sends a per-launch `X-Auth-Token` on every request.
- **Sidecar cleanup is belt-and-suspenders:** the app calls `stop()` on `willTerminate`, *and*
  `server.py` runs a stdin-EOF watchdog so it self-terminates if the app crashes. Both prevent
  orphaned Python. The watchdog only runs when `REZKA_SIDECAR_MANAGED=1` (set by the app) — else a
  manual/CI `python server.py` would exit instantly on already-EOF stdin.
- **All scraping lives in the sidecar.** Swift never parses HTML. To add a capability: add a
  `server.py` endpoint (register in `ROUTES`) + a method on `APIClient.swift` + a model in
  `Models.swift`.
- **Every sidecar request carries `origin` and (when logged in) `cookies`, plus an optional
  `proxy`.** `APIClient` injects `origin`/`cookies` automatically via providers wired in `AppState`.
- **Vendored code hygiene:** `sidecar/hdrezka/` stays a clean upstream mirror *except* `VENDOR
  PATCH`-marked edits (documented in `sidecar/hdrezka/VENDORED.md` — currently: movie CDN flags, the
  `favs` token, and a richer `FetchFailed`). Our own features go in `sidecar/browse.py` /
  `server.py`, never inside `hdrezka/`.
- **Player:** uses AppKit `AVPlayerView` via `NSViewRepresentable` (`PlayerView.swift`). **Do not use
  SwiftUI `VideoPlayer`** — it crashes during view-metadata instantiation on macOS 26.

### App data stores (all `@MainActor ObservableObject`, owned by `AppState`)

Persist JSON to `~/Library/Application Support/RezkaPlayer/` (login cookies go to the Keychain):

| Store | File | What |
|-------|------|------|
| `DownloadManager` | `library.json` + `Media/` | downloads (+ pause/resume, notifications) |
| `BookmarkStore` | `watchlater.json` | Watch Later |
| `WatchedStore` | `watched.json` | watched/History |
| `ProgressStore` | `progress.json` | resume positions / Continue Watching |
| `PreferenceStore` | `lasttranslator.json` | per-title last translator |
| `Keychain.swift` | macOS Keychain | HDRezka session cookies |

`AppState` re-publishes each store's `objectWillChange` (sinks in `init()`), holds `@AppStorage`
prefs (`hdrezkaOrigin`, `proxyURL`, `preferredQuality`, `hideWatched`, `hdrezkaEmail`), and exposes
`login/logout`, `pushProxyConfig`, and `playbackURLString(for:)` (relay rewriting). Sidebar sections
are an enum in `RootView.swift` (`sectionRoot` switch). The menu bar + notification auth live in
`RezkaPlayerApp.swift` / `DownloadManager.swift`.

## Sidecar endpoints

POST + JSON (except `GET /health`, `GET /relay`). Body includes `origin`; may include `cookies`,
`proxy`, `headers`.

| Endpoint   | Body                                                        | Returns |
|------------|-------------------------------------------------------------|---------|
| `GET /health` | —                                                        | `{ok, version, categories, collections, genres, sorts, proxy}` |
| `/config`  | `proxy` (`"socks5://.."` or `""`)                           | `{ok, proxy}` — process-wide proxy for all traffic |
| `/search`  | `query`, `find_all?`, `page?`                               | `{results: [CatalogueItem]}` |
| `/browse`  | `collection`, `category`, `page?`, `genre?`, `year?`, `sort?` | `{results: [CatalogueItem]}` |
| `/info`    | `url`                                                       | `TitleInfo` (metadata, translators, episodes?, **similar**) |
| `/stream`  | `url`, `translation?`, `season?`, `episode?`               | `{videos: {quality:[urls]}, subtitles, ...}` |
| `/login`   | `email`, `password` (+ `origin`)                           | `{ok, cookies?, message?}` |
| `GET /relay` | query: `u`=b64url(cdn), `t`=token, `r`=b64url(origin)     | streams the video (Range-aware) through the configured proxy |

`browse` paths: genre → `/{cat}/{genre}/`; `sort=best` → `/{cat}/best/[{year}/]`;
`last/popular/soon/watching` → `?filter=…`. Genre slugs + sort options come from `browse.GENRES`/
`SORTS` (also surfaced in `/health`; the Swift `CatalogueGenres` enum mirrors them — keep in sync).

### Proxy / relay (geo-restriction)

HDRezka's video CDN is geo-blocked in some regions; AVPlayer/URLSession can't use a SOCKS proxy
directly, so geo-sensitive traffic is funneled through the sidecar. Set a proxy via `/config`; the
app rewrites stream/download URLs to `GET /relay?u=…` (`AppState.playbackURLString`). The relay
fetches CDN bytes through the proxy and forwards Range requests for seeking. `u`/`r` are URL-safe
base64 (`AppState.b64url` ↔ `server._b64url_decode`). SOCKS needs `PySocks` (`socks5://` → `socks5h://`
so DNS resolves at the proxy).

## Known gotcha — streaming is IP-gated

HDRezka's CDN returns `success:true` but `url:false` for **every** translation from a
datacenter/blocked IP (and even 403s the whole site on some hosting ASNs like Hetzner). `/browse`
and `/info` work from the same IP — only stream generation/delivery is geo-gated. So a `/stream`
`FetchFailed` in a sandbox/CI is usually **not** a code bug; verify from a residential connection or
via the in-app proxy.

## Packaging & distribution

- `scripts/build-sidecar.sh` — PyInstaller **onedir** freeze of the sidecar (onefile was ~7s
  startup; onedir ~1s). Includes requests/bs4/PySocks + vendored `hdrezka`.
- `scripts/package.sh` — Release build → bundle the frozen sidecar into `Resources/` → ad-hoc sign
  inside-out → `build/RezkaPlayer.dmg` (Apple Silicon, hardened runtime OFF — not notarized).
- `.github/workflows/release.yml` — on a `v*` tag, runs `package.sh` on a macOS runner and publishes
  the DMG as a GitHub Release.
- First launch on a recipient's Mac needs right-click → Open or
  `xattr -dr com.apple.quarantine /Applications/RezkaPlayer.app`.

## Decisions made (don't re-litigate without reason)

- Architecture: **SwiftUI app + bundled Python sidecar** (not pure Python; a pure-Swift/iOS port is
  in `BACKLOG.md`).
- Domain configurable in Settings (default `https://hdrezka.ag`); HDRezka geo-blocks the CDN.
- Login implemented (Keychain cookies). Downloads are direct `.mp4` per resolution via `URLSession`.
- Distribution: free **ad-hoc DMG** (right-click-Open). Notarization + Sparkle auto-update are
  deferred in `BACKLOG.md`.

## Backlog

See `BACKLOG.md`: Sparkle auto-update + public releases, follow-series + new-episode notifications,
iOS port (pure-Swift core).
