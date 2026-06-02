#!/usr/bin/env python3
"""
Local JSON HTTP sidecar for the RezkaPlayer macOS app.

The SwiftUI app spawns this process on 127.0.0.1 and talks to it over HTTP. All HDRezka
scraping happens here via the vendored `hdrezka` package + our `browse` module.

Endpoints (all POST with a JSON body, except /health):
  GET  /health                          -> {"ok": true, "version": ...}
  POST /search   {origin, query, find_all?}            -> [{title,url,rating|image,category}]
  POST /browse   {origin, collection?, category?, page?} -> [{title,url,image,category,rating,...}]
  POST /info     {origin, url}                          -> {metadata, translators, episodes?}
  POST /stream   {origin, url, translation?, season?, episode?} -> {videos, subtitles, ...}

Every request may include {cookies?, proxy?} so the app can add login/proxy later without a
protocol change. `origin` is the configurable HDRezka mirror.

Auth: if env REZKA_SIDECAR_TOKEN is set, requests must send header `X-Auth-Token` matching it.
"""

import argparse
import json
import os
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urljoin

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from hdrezka.api import HdRezkaApi
from hdrezka.search import HdRezkaSearch
from hdrezka.types import TVSeries, Movie
from browse import Browse, CATEGORIES, COLLECTIONS

__version__ = "0.1.0"
AUTH_TOKEN = os.environ.get("REZKA_SIDECAR_TOKEN")


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
        proxy=body.get("proxy") or {},
        cookies=body.get("cookies") or {},
        headers=body.get("headers") or {},
    )


# ---------- endpoint handlers ----------

def h_health(_body):
    return {"ok": True, "version": __version__,
            "categories": CATEGORIES, "collections": list(COLLECTIONS.keys())}


def h_search(body):
    origin = body["origin"]
    query = body["query"]
    find_all = bool(body.get("find_all"))
    search = HdRezkaSearch(origin, proxy=body.get("proxy") or {},
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
    b = Browse(origin, proxy=body.get("proxy") or {},
               cookies=body.get("cookies") or {})
    items = b.list(
        collection=body.get("collection", "best"),
        category=body.get("category", "films"),
        page=int(body.get("page", 1)),
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
            for tid, v in api.translators.items()
        ],
        "otherParts": _safe(lambda: api.otherParts) or [],
    }
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


def _safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


ROUTES = {
    "/search": h_search,
    "/browse": h_browse,
    "/info": h_info,
    "/stream": h_stream,
}


# ---------- HTTP plumbing ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quieter logs
        sys.stderr.write("[sidecar] " + (args[0] % args[1:]) + "\n")

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if not AUTH_TOKEN:
            return True
        return self.headers.get("X-Auth-Token") == AUTH_TOKEN

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            return self._send(200, h_health({}))
        return self._send(404, {"error": "not found"})

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
