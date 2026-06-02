# Vendored: HdRezkaApi

This directory is a **copy** of [SuperZombi/HdRezkaApi](https://github.com/SuperZombi/HdRezkaApi),
vendored so we can maintain/patch the scraping logic ourselves when HDRezka changes.

- Upstream commit: `d686a2d48ba530ad9034e44eb554d095bd8da82f`
- Upstream version: `11.2.3`
- License: MIT (Super_Zombi)

When upstream fixes a scraping break, diff their package against this folder and port the change.
Our own additions (catalogue/top-ranked browsing) live in `sidecar/browse.py`, **not** here, to keep
this copy a clean mirror of upstream.

## Our patches on top of upstream

Search for `VENDOR PATCH` in this folder. Current patches:

- **api.py `getStreamMovie`** — send `is_camrip`/`is_ads`/`is_director` flags (parsed from the
  page's `initCDNMoviesEvents` call). HDRezka started requiring them; without them the movie CDN
  request returns `success:true` but `url:false`.
- **api.py `favs` + `makeRequest`** — parse the per-page `#ctrl_favs` UUID token and send it as
  `favs` on every get_stream/get_movie CDN call, plus the `X-Requested-With`/`Referer` headers a
  browser sends. HDRezka added `favs` as anti-scraping; without it the CDN returns
  `success:true, url:false`. `makeRequest` also now raises a descriptive `FetchFailed` message
  (geo-restriction / login / premium hints) instead of a bare "Failed to fetch stream!".
- **errors.py `FetchFailed`** — accepts an optional message (for the diagnostics above).
