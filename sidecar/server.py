#!/usr/bin/env python3
"""
Local JSON HTTP sidecar for the RezkaPlayer macOS app.

The SwiftUI app spawns this process on 127.0.0.1 and talks to it over HTTP. All HDRezka
scraping happens here via the vendored `hdrezka` package + our `browse` module.

Endpoints (POST + JSON body, except GET /health and GET /relay):
  GET  /health                          -> {"ok": true, "version": ...}
  POST /config   {proxy?}               -> set a process-wide proxy used for ALL traffic
  POST /search   {origin, query, find_all?}            -> [{title,url,rating|image,category}]
  POST /browse   {origin, collection?, category?, page?} -> [{title,url,image,category,rating,...}]
  POST /info     {origin, url}                          -> {metadata, translators, episodes?}
  POST /stream   {origin, url, translation?, season?, episode?} -> {videos, subtitles, ...}
  GET  /relay?u=<urlenc cdn>&t=<token>&r=<referer> -> streams the video bytes (Range-aware)
                                          through the configured proxy, so AVPlayer/URLSession
                                          (which can't use a SOCKS proxy directly) egress via it.

`origin` is the configurable HDRezka mirror. A proxy set via /config is applied to every request,
including the video relay — this is how we tunnel geo-restricted CDN traffic.

Auth: if env REZKA_SIDECAR_TOKEN is set, requests must send header `X-Auth-Token` (or, for /relay,
the `t` query param) matching it.
"""

import argparse
import base64
import json
import os
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urljoin, urlparse, parse_qs

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import anubis
# Transparently clear HDRezka's Anubis proof-of-work anti-bot gateway on every request the
# sidecar makes (scraping only; the streamed /relay pull is left untouched). Must run before
# any hdrezka/browse request is issued. See anubis.py.
anubis.install()

from hdrezka.api import HdRezkaApi
from hdrezka.search import HdRezkaSearch
from hdrezka.types import TVSeries, Movie, default_headers
from hdrezka.errors import LoginFailed
from browse import Browse, CATEGORIES, COLLECTIONS, GENRES, SORTS, parse_similar

__version__ = "0.2.0"
AUTH_TOKEN = os.environ.get("REZKA_SIDECAR_TOKEN")

# Process-wide proxy (requests-style {"http":..,"https":..}), set via POST /config.
# Applied to scraping AND the video relay so all geo-sensitive traffic shares one egress.
PROXY = {}


def build_proxies(proxy):
    """Normalize a proxy spec into a requests proxies dict.
    Accepts a dict (returned as-is) or a string like 'socks5://user:pass@host:1080',
    'http://host:8080', or bare 'host:1080' (assumed SOCKS5 with remote DNS)."""
    if not proxy:
        return {}
    if isinstance(proxy, dict):
        return proxy
    s = str(proxy).strip()
    if not s:
        return {}
    if "://" not in s:
        s = "socks5h://" + s          # bare host:port -> SOCKS5 with DNS at the proxy
    elif s.startswith("socks5://"):
        s = "socks5h://" + s[len("socks5://"):]   # resolve DNS at proxy (better for geo)
    return {"http": s, "https": s}


def proxy_for(body):
    """Per-request proxy override, else the process-wide PROXY."""
    p = build_proxies(body.get("proxy"))
    return p or PROXY


def _b64url_decode(s):
    """Decode URL-safe base64 without padding (how the app encodes relay params)."""
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode("ascii")).decode("utf-8")


# ---------- serialization helpers ----------

def abs_url(origin, url):
    """Resolve a possibly-relative HDRezka URL (e.g. '/films/x.html') against the origin.
    Some mirrors return relative hrefs in search/browse listings."""
    if not url:
        return url
    return urljoin(origin.rstrip("/") + "/", url)


def ser_type(t):
    if t is None:
        return None
    return {"name": getattr(t, "name", None), "type": getattr(t, "type", None)}


def ser_rating(r):
    if r is None:
        return None
    try:
        value = r.value
    except Exception:
        value = None
    if value is None:
        return None
    return {"value": float(r.value), "votes": int(r.votes) if r.votes is not None else None}


def make_api(body):
    origin = body["origin"]
    url = abs_url(origin, body.get("url") or origin)
    return HdRezkaApi(
        url,
        proxy=proxy_for(body),
        cookies=body.get("cookies") or {},
        headers=body.get("headers") or {},
    )


# ---------- endpoint handlers ----------

def h_health(_body):
    # Expose genres + sort options so the app can populate its filter menus.
    genres = {cat: [{"slug": slug, "label": label} for slug, label in items]
              for cat, items in GENRES.items()}
    return {"ok": True, "version": __version__,
            "categories": CATEGORIES, "collections": list(COLLECTIONS.keys()),
            "genres": genres, "sorts": SORTS,
            "proxy": bool(PROXY)}


def h_config(body):
    """Set the process-wide proxy. Body: {proxy: "socks5://.."|""|null}."""
    global PROXY
    PROXY = build_proxies(body.get("proxy"))
    return {"ok": True, "proxy": bool(PROXY)}


def h_search(body):
    origin = body["origin"]
    query = body["query"]
    find_all = bool(body.get("find_all"))
    search = HdRezkaSearch(origin, proxy=proxy_for(body),
                           cookies=body.get("cookies") or {})
    if not find_all:
        results = search.fast_search(query)
        for it in results:
            it["url"] = abs_url(origin, it.get("url"))
        return {"results": results}
    # advanced search: collect first page (or requested page)
    res = search.advanced_search(query)
    page = int(body.get("page", 1))
    items = res.get_page(page) or []
    out = []
    for it in items:
        it = dict(it)
        it["url"] = abs_url(origin, it.get("url"))
        it["category"] = ser_type(it.get("category"))
        out.append(it)
    return {"results": out}


def h_browse(body):
    origin = body["origin"]
    b = Browse(origin, proxy=proxy_for(body),
               cookies=body.get("cookies") or {})
    items = b.list(
        collection=body.get("collection", "best"),
        category=body.get("category", "films"),
        page=int(body.get("page", 1)),
        genre=body.get("genre"),
        year=body.get("year"),
        sort=body.get("sort"),
    )
    for it in items:
        it["url"] = abs_url(origin, it.get("url"))
    return {"results": items}


def h_info(body):
    api = make_api(body)
    if not api.ok:
        raise api.exception or RuntimeError("Failed to load page")

    data = {
        "id": api.id,
        "url": api.url,
        "name": api.name,
        "names": api.names,
        "origName": api.origName,
        "origNames": api.origNames,
        "description": _safe(lambda: api.description),
        "thumbnail": _safe(lambda: api.thumbnail),
        "thumbnailHQ": _safe(lambda: api.thumbnailHQ),
        "releaseYear": _safe(lambda: api.releaseYear),
        "type": ser_type(api.type),
        "category": ser_type(api.category),
        "rating": ser_rating(_safe(lambda: api.rating)),
        "isSeries": api.type == TVSeries,
        "translators": [
            {"id": tid, "name": v["name"], "premium": v["premium"]}
            for tid, v in (_safe(lambda: api.translators) or {}).items()
        ],
        "otherParts": _safe(lambda: api.otherParts) or [],
    }
    # Related/similar titles from the detail page (same shape as catalogue items).
    similar = _safe(lambda: parse_similar(api.soup)) or []
    for it in similar:
        it["url"] = abs_url(api.origin, it.get("url"))
    data["similar"] = similar
    if api.type == TVSeries:
        # episodesInfo: [{season, season_text, episodes:[{episode, episode_text, translations:[...]}]}]
        data["episodes"] = _safe(lambda: api.episodesInfo) or []
    return data


def h_stream(body):
    api = make_api(body)
    if not api.ok:
        raise api.exception or RuntimeError("Failed to load page")
    season = body.get("season")
    episode = body.get("episode")
    translation = body.get("translation")
    stream = api.getStream(
        season=season, episode=episode, translation=translation,
    )
    subs = []
    try:
        for code, val in stream.subtitles.subtitles.items():
            subs.append({"code": code, "title": val["title"], "link": val["link"]})
    except Exception:
        pass
    return {
        "name": stream.name,
        "season": stream.season,
        "episode": stream.episode,
        "translatorId": stream.translator_id,
        # {"360p": [url, ...], "720p": [...], ...}
        "videos": stream.videos,
        "subtitles": subs,
    }


def h_login(body):
    """Log into HDRezka. Body: {origin, email, password}.
    On success returns {ok:true, cookies:{..}} (the dle_user_id/dle_password session
    cookies to send on subsequent requests); on failure {ok:false, message:..}."""
    origin = body["origin"]
    email = body.get("email") or ""
    password = body.get("password") or ""
    api = HdRezkaApi(origin, proxy=proxy_for(body),
                     cookies=body.get("cookies") or {})
    try:
        api.login(email, password)   # merges session cookies into api.cookies on success
    except LoginFailed as e:
        return {"ok": False, "message": str(e) or "Login failed"}
    except Exception as e:
        return {"ok": False, "message": str(e) or "Login failed"}
    return {"ok": True, "cookies": api.cookies}


def _safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


ROUTES = {
    "/config": h_config,
    "/search": h_search,
    "/browse": h_browse,
    "/info": h_info,
    "/stream": h_stream,
    "/login": h_login,
}

# Headers a browser sends to HDRezka's CDN; some edges require a UA/Referer.
RELAY_HEADERS = {**default_headers}
# Headers we pass through from the client (AVPlayer) to the upstream CDN.
RELAY_FORWARD = ("range",)
# Upstream response headers we surface back to the client.
RELAY_EXPOSE = ("content-type", "content-length", "content-range", "accept-ranges")

# Where the app stores completed downloads. `GET /media` serves files from here (and only here)
# so an AirPlay receiver can fetch a downloaded episode over the LAN — a `file://` URL means
# nothing to the TV. Keyed by base name; anything with a path separator is rejected.
MEDIA_DIR = os.path.expanduser("~/Library/Application Support/RezkaPlayer/Media")


# ---------- HTTP plumbing ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quieter logs
        sys.stderr.write("[sidecar] " + (args[0] % args[1:]) + "\n")

    def _send(self, code, payload, with_body=True):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if with_body:                      # HEAD: headers only, per RFC 9110
            self.wfile.write(body)

    def _authed(self):
        if not AUTH_TOKEN:
            return True
        return self.headers.get("X-Auth-Token") == AUTH_TOKEN

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            return self._send(200, h_health({}))
        if path == "/relay":
            return self._relay()
        if path == "/media":
            return self._media()
        return self._send(404, {"error": "not found"})

    def do_HEAD(self):
        """Same routes as GET but headers only. AirPlay receivers (Apple TV, smart TVs) probe a
        media URL with HEAD before fetching it — without this, BaseHTTPRequestHandler answers
        `501 Unsupported method` and the receiver gives up, so the TV never plays the video."""
        path = self.path.split("?")[0]
        if path == "/health":
            return self._send(200, h_health({}), with_body=False)
        if path == "/relay":
            return self._relay(with_body=False)
        if path == "/media":
            return self._media(with_body=False)
        return self._send(404, {"error": "not found"}, with_body=False)

    def _media(self, with_body=True):
        """Serve a completed download from MEDIA_DIR over HTTP, Range-aware, so an AirPlay
        receiver can pull it from this Mac (a `file://` URL is unusable by the TV). Only base
        names inside MEDIA_DIR are served, and the per-launch token is required."""
        q = parse_qs(urlparse(self.path).query)
        token = (q.get("t") or [None])[0]
        if AUTH_TOKEN and token != AUTH_TOKEN and self.headers.get("X-Auth-Token") != AUTH_TOKEN:
            return self._send(401, {"error": "unauthorized"}, with_body=with_body)
        raw_f = (q.get("f") or [None])[0]
        if not raw_f:
            return self._send(400, {"error": "missing f"}, with_body=with_body)
        try:
            name = _b64url_decode(raw_f)
        except Exception:
            return self._send(400, {"error": "bad f"}, with_body=with_body)
        # Base name only — no traversal, no absolute paths, and the result must stay in MEDIA_DIR.
        if not name or name != os.path.basename(name):
            return self._send(400, {"error": "bad name"}, with_body=with_body)
        full = os.path.realpath(os.path.join(MEDIA_DIR, name))
        if not full.startswith(os.path.realpath(MEDIA_DIR) + os.sep) or not os.path.isfile(full):
            return self._send(404, {"error": "no such file"}, with_body=with_body)

        size = os.path.getsize(full)
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            spec = rng[len("bytes="):].split(",")[0].strip()
            try:
                if spec.startswith("-"):                    # suffix range: last N bytes
                    start, end = max(0, size - int(spec[1:])), size - 1
                else:
                    a, _, b = spec.partition("-")
                    start = int(a)
                    end = int(b) if b else size - 1
            except ValueError:
                return self._send(400, {"error": "bad range"}, with_body=with_body)
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if not with_body:
            return
        try:
            with open(full, "rb") as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # receiver seeked or stopped; normal

    def _relay(self, with_body=True):
        """Stream a CDN video to the client through the configured proxy, forwarding Range
        requests so AVPlayer can seek. This is how playback/downloads egress via the proxy.
        With `with_body=False` (HEAD) the upstream headers are relayed and the body skipped."""
        q = parse_qs(urlparse(self.path).query)
        token = (q.get("t") or [None])[0]
        if AUTH_TOKEN and token != AUTH_TOKEN and self.headers.get("X-Auth-Token") != AUTH_TOKEN:
            return self._send(401, {"error": "unauthorized"}, with_body=with_body)
        raw_u = (q.get("u") or [None])[0]
        if not raw_u:
            return self._send(400, {"error": "missing u"}, with_body=with_body)
        try:
            target = _b64url_decode(raw_u)             # CDN url, base64url-encoded by the app
        except Exception:
            return self._send(400, {"error": "bad u"}, with_body=with_body)
        raw_r = (q.get("r") or [None])[0]
        referer = _b64url_decode(raw_r) if raw_r else None

        headers = dict(RELAY_HEADERS)
        if referer:
            headers["Referer"] = referer
        for h in RELAY_FORWARD:
            v = self.headers.get(h)
            if v:
                headers[h] = v

        try:
            upstream = requests.get(target, headers=headers, proxies=PROXY,
                                    stream=True, allow_redirects=True, timeout=(15, 60))
        except Exception as e:
            return self._send(502, {"error": f"relay failed: {e}"}, with_body=with_body)

        try:
            self.send_response(upstream.status_code)
            passed_len = False
            for h in RELAY_EXPOSE:
                if h in upstream.headers:
                    self.send_header(h.title(), upstream.headers[h])
                    if h == "content-length":
                        passed_len = True
            if not passed_len:
                # No length -> we can't keep-alive; close after streaming.
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if not with_body:
                return                      # HEAD probe satisfied; don't pull the video
            for chunk in upstream.iter_content(64 * 1024):
                if chunk:
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client (AVPlayer) seeked or closed; normal
        except Exception:
            traceback.print_exc()
        finally:
            upstream.close()

    def do_POST(self):
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        route = ROUTES.get(self.path.split("?")[0])
        if route is None:
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw or b"{}")
        except Exception as e:
            return self._send(400, {"error": f"bad request: {e}"})
        try:
            result = route(body)
            return self._send(200, result)
        except KeyError as e:
            return self._send(400, {"error": f"missing field: {e}"})
        except Exception as e:
            traceback.print_exc()
            return self._send(502, {"error": str(e), "type": e.__class__.__name__})


def _watch_parent_via_stdin():
    """Exit if our parent (the app) goes away: it holds the write end of our stdin,
    so EOF here means the app closed/crashed. Safety net beyond a clean shutdown."""
    try:
        while sys.stdin.readline():
            pass
    except Exception:
        pass
    os._exit(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8777)
    args = ap.parse_args()

    # Only watch stdin when the app launched us (it holds the write end open). Manual/CI runs
    # would otherwise see immediate EOF and exit. The app sets REZKA_SIDECAR_MANAGED=1.
    if os.environ.get("REZKA_SIDECAR_MANAGED") == "1":
        threading.Thread(target=_watch_parent_via_stdin, daemon=True).start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    # Print a machine-readable ready line so the app knows the actual bound port.
    print(f"SIDECAR_READY host={args.host} port={server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
