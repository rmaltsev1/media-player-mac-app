# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

**RezkaPlayer** — a native macOS media player for browsing, streaming, and downloading from
HDRezka. It is a personal-use tool. Two parts:

- **`app/`** — SwiftUI macOS app (the UI, AVKit player, downloads, offline library).
- **`sidecar/`** — a Python helper the app spawns on `127.0.0.1`; it does *all* HDRezka scraping.

The app talks to the sidecar over local HTTP (JSON). The scraping library
[SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi) is **vendored** under
`sidecar/hdrezka/` and maintained here (so we can patch when HDRezka changes).

## Build & run

```bash
# Sidecar (Python 3.9+). The app launches it automatically, but for manual testing:
cd sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python server.py --port 8777        # endpoints below; prints "SIDECAR_READY ... port=N"

# App (needs Xcode 26 + xcodegen: `brew install xcodegen`)
cd app
xcodegen generate                   # regenerates RezkaPlayer.xcodeproj from project.yml
xcodebuild -project RezkaPlayer.xcodeproj -scheme RezkaPlayer -configuration Debug build
open RezkaPlayer.xcodeproj           # then ⌘R, or `open` the built .app
```

The built app lives under `~/Library/Developer/Xcode/DerivedData/RezkaPlayer-*/Build/Products/Debug/RezkaPlayer.app`.

## Architecture & conventions

- **`app/project.yml`** is the source of truth for the Xcode project. The `.xcodeproj` is
  **gitignored and regenerated** — never hand-edit it; edit `project.yml` and run `xcodegen generate`.
- **Sidecar process management** (`app/Sources/RezkaPlayer/Sidecar.swift`): the app spawns
  `server.py --port 0` (OS picks a free port), reads the `SIDECAR_READY host=.. port=N` stdout
  line, and sends a per-launch `X-Auth-Token` header on every request.
- **Sidecar cleanup is belt-and-suspenders:** the app calls `stop()` on `willTerminate`, *and*
  `server.py` runs a stdin-EOF watchdog thread so it self-terminates if the app crashes /
  force-quits. Don't remove either — together they prevent orphaned Python processes. The watchdog
  only runs when `REZKA_SIDECAR_MANAGED=1` (set by the app); otherwise a manual/CI `python
  server.py` would exit instantly on its already-EOF stdin.
- **All scraping lives in the sidecar.** Swift never scrapes HTML. To add a capability, add a
  `server.py` endpoint + a method on `APIClient`, then a model in `Models.swift`.
- **Every sidecar request accepts `cookies` and `proxy`** (login + geo-bypass were designed in
  even though login UI isn't built yet). Keep this in the request shape.
- **Vendored code hygiene:** `sidecar/hdrezka/` should stay a clean mirror of upstream *except* for
  changes marked `VENDOR PATCH` (documented in `sidecar/hdrezka/VENDORED.md`). Our own features go
  in sibling modules like `sidecar/browse.py`, not inside `hdrezka/`.

## Sidecar endpoints

All POST + JSON (except `GET /health`). Body always includes `origin` (the HDRezka mirror);
may include `cookies`, `proxy`, `headers`.

| Endpoint   | Body                                              | Returns |
|------------|---------------------------------------------------|---------|
| `GET /health`  | —                                             | `{ok, version, categories, collections, proxy}` |
| `/config`  | `proxy` (`"socks5://.."` or `""`)                 | `{ok, proxy}` — sets a process-wide proxy for all traffic |
| `/search`  | `query`, `find_all?`, `page?`                      | `{results: [CatalogueItem]}` |
| `/browse`  | `collection` (best/latest/watching), `category`, `page?` | `{results: [CatalogueItem]}` |
| `/info`    | `url`                                              | `TitleInfo` (metadata, translators, episodes?) |
| `/stream`  | `url`, `translation?`, `season?`, `episode?`      | `{videos: {quality:[urls]}, subtitles, ...}` |
| `GET /relay` | query: `u`=b64url(cdn), `t`=token, `r`=b64url(origin) | streams the video (Range-aware) through the configured proxy |

### Proxy / relay (geo-restriction)

HDRezka's video CDN is geo-blocked in some regions. AVPlayer/URLSession can't use a SOCKS proxy
directly, so geo-sensitive traffic is funneled through the sidecar: set a proxy via `/config`, and
the app rewrites stream/download URLs to the local `GET /relay?u=...` endpoint
(`AppState.playbackURLString`). The relay fetches the CDN bytes through the proxy and forwards Range
requests so AVPlayer can seek. `u`/`r` are URL-safe base64 (see `AppState.b64url` ↔
`server._b64url_decode`) to avoid percent/`+` decoding ambiguity. SOCKS needs `PySocks`
(`socks5://` is upgraded to `socks5h://` so DNS resolves at the proxy).

## Known gotcha — streaming is IP-gated

HDRezka's CDN returns `success:true` but `url:false` for **every** translation when the request
comes from a datacenter / blocked IP. `/browse` and `/info` still work from the same IP — only
stream-URL generation is geo-gated. So a `/stream` `FetchFailed` in a sandbox/CI is usually **not**
a code bug; verify streaming from a residential connection or via the in-app proxy setting.

## Decisions already made (don't re-litigate without reason)

- Architecture: **SwiftUI app + Python sidecar** (not pure Python, not a full Swift port).
- Login: **anonymous now**, but cookie/session layer is wired for later.
- Domain: **configurable in Settings** (HDRezka rotates/geo-blocks domains); default `https://hdrezka.ag`.
- Downloads: direct `.mp4` per resolution via `URLSession`, stored in Application Support, library
  persisted as JSON.

## Before distributing (not done yet)

The app currently runs **unsandboxed** and points at the dev repo's `sidecar/` by absolute path
(overridable in Settings). To ship: bundle a standalone Python + deps as an app Resource, point
`SidecarManager` at the bundled copy, and re-enable `com.apple.security.app-sandbox`.
