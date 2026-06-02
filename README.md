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

## Streaming from a geo-blocked region (proxy)

HDRezka's **video CDN** is geo-blocked in some regions (e.g. the UK): the site loads, but stream
URLs come back empty (`success:true, url:false`). Because the video bytes are fetched by AVPlayer /
URLSession — which can't use a SOCKS proxy directly — the app routes **all** geo-sensitive traffic
(scraping **and** playback **and** downloads) through the Python sidecar:

- Set a **Proxy URL** in Settings, e.g. `socks5://user:pass@host:1080` (HTTP proxies work too).
- The sidecar uses it for scraping, and exposes a local `/relay` endpoint that streams the video
  through the proxy with HTTP Range support, so playback and downloads egress via the proxy while
  the rest of your Mac stays on its normal connection.

Most consumer VPNs can give you a standalone **SOCKS5 endpoint** (works without the VPN app being
"connected"): e.g. Private Internet Access, NordVPN, Windscribe, Mullvad. Use that host/port (and
credentials, if any) in the Proxy field. Alternatively, just run a system-wide VPN and leave the
Proxy field empty.

## Notes & limitations

- **Streaming is IP-gated.** HDRezka's CDN won't generate stream URLs for blocked/datacenter IPs
  (it returns `success:true, url:false`). Browsing and metadata still work; streaming needs a
  permitted region — see the proxy section above. This is not an app bug.
- **Dev build runs unsandboxed** and points at this repo's `sidecar/` folder by default
  (overridable in Settings). Before distributing, a standalone Python should be bundled and the
  sandbox re-enabled — see `CLAUDE.md`.

See **`CLAUDE.md`** for architecture details, conventions, and the endpoint reference.

## Legal

Personal-use tool. HDRezka hosts third-party content; you are responsible for complying with the
laws and terms applicable in your jurisdiction.
