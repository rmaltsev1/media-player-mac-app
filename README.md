# Rezka Player (macOS)

A native macOS app for browsing, streaming, and downloading from HDRezka — built for personal use.

Built on top of [SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi), which is
**vendored and self-maintained** under `sidecar/hdrezka/` so the scraping logic can be patched
in-tree when HDRezka changes.

## Features

- **Browse the catalogue** — Films, Series, Cartoons, Anime, plus a "Now Watching" home feed.
- **Top-ranked / Latest** toggle per category.
- **Search** HDRezka by title (poster grid results).
- **Stream in-app** with an AVKit player — pick the **translation** (dub/voiceover/subs) and the
  **resolution** (360p–1080p Ultra). Series get season/episode pickers.
- **Download** any title in the resolution you choose; watch it **offline** from the Downloads tab.
- **Configurable mirror** — paste a working HDRezka domain in Settings (it rotates / geo-blocks),
  with optional proxy support designed in.

## Architecture

```
┌──────────────────────────────┐
│  RezkaPlayer.app (SwiftUI)    │   Native UI · AVKit player · downloads · offline library
│  - browses catalogue / top    │
│  - streams & downloads        │
└───────────────┬──────────────┘
        local HTTP (127.0.0.1, token-guarded)
┌───────────────┴──────────────┐
│  Python sidecar               │   stdlib http.server + vendored HdRezkaApi + our browse module
│  (server.py)                  │   search / browse / info / stream
└──────────────────────────────┘
```

- **`app/`** — SwiftUI macOS app. The Xcode project is generated from `app/project.yml` via
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the `.xcodeproj` is gitignored).
- **`sidecar/`** — Python helper the app spawns on a local port and talks to over JSON/HTTP.
  - **`sidecar/hdrezka/`** — vendored HdRezkaApi (mirror of upstream; only `VENDOR PATCH`-marked
    edits, documented in `VENDORED.md`).
  - **`sidecar/browse.py`** — our catalogue / top-ranked browsing (HDRezka list pages).
  - **`sidecar/server.py`** — the local JSON server (`/health`, `/search`, `/browse`, `/info`,
    `/stream`).

## Getting started

```bash
# 1. Sidecar deps (Python 3.9+). The app launches the sidecar itself; this is just the venv it uses.
cd sidecar
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 2. App (needs Xcode 26 and xcodegen: `brew install xcodegen`)
cd ../app
xcodegen generate
open RezkaPlayer.xcodeproj          # ⌘R to run
```

On first run, open **Settings** and set the HDRezka mirror domain you want to use.

## Notes & limitations

- **Streaming is IP-gated.** HDRezka's CDN won't generate stream URLs for many datacenter IPs
  (it returns `success:true, url:false`). Browsing and metadata still work; streaming needs a
  residential connection or the in-app proxy. This is not an app bug.
- **Dev build runs unsandboxed** and points at this repo's `sidecar/` folder by default
  (overridable in Settings). Before distributing, a standalone Python should be bundled and the
  sandbox re-enabled — see `CLAUDE.md`.

See **`CLAUDE.md`** for architecture details, conventions, and the endpoint reference.

## Legal

Personal-use tool. HDRezka hosts third-party content; you are responsible for complying with the
laws and terms applicable in your jurisdiction.
