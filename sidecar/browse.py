"""
Catalogue / top-ranked browsing for HDRezka.

This is OUR addition (not part of upstream HdRezkaApi). HDRezka's list pages
(`/films/`, `/series/best/`, the homepage, genre pages, ...) all render items with the
same `.b-content__inline_item` markup that the upstream search results use, so we parse
them the same way and reuse the type detection from the vendored library.
"""

import requests
from bs4 import BeautifulSoup

from hdrezka.types import default_cookies, default_headers
from hdrezka.search import SearchResult  # process_item / detect_type live here
from hdrezka.errors import HTTP, LoginRequiredError, CaptchaError


# Catalogue categories as they appear in HDRezka URL paths.
CATEGORIES = ["films", "series", "cartoons", "animation"]

# Logical collections the app can request -> (path template, label).
# `{cat}` is filled with a category; `{page}` with the page number.
COLLECTIONS = {
    "latest":  "/{cat}/",            # newest additions in a category
    "best":    "/{cat}/best/",       # top-ranked in a category
    "watching": "/",                 # homepage "now watching" (category ignored)
}


def _rating_from_item(item):
    el = item.find(class_="b-content__inline_item-link")
    if not el:
        return None
    info = el.find("div")
    # ratings on list pages are not always present; best-effort
    rating_el = item.find(class_="b-category-bestrating") or item.find("i", class_="hd-tooltip")
    if rating_el:
        txt = rating_el.get_text().strip()
        try:
            return float(txt)
        except ValueError:
            return None
    return None


def _serialize_type(t):
    if t is None:
        return None
    # HdRezkaType -> {"name","type"} (e.g. {"name":"film","type":"category"})
    return {"name": getattr(t, "name", None), "type": getattr(t, "type", None)}


def _parse_listing(html):
    soup = BeautifulSoup(html, "html.parser")
    if soup.title and soup.title.text == "Sign In":
        raise LoginRequiredError()
    if soup.title and soup.title.text == "Verify":
        raise CaptchaError()

    results = []
    for item in soup.find_all(class_="b-content__inline_item"):
        try:
            parsed = SearchResult.process_item(item)  # {title,url,image,category}
        except Exception:
            continue
        parsed["category"] = _serialize_type(parsed.get("category"))
        parsed["rating"] = _rating_from_item(item)
        # year/extra info, when present
        info = item.find(class_="b-content__inline_item-link")
        if info:
            sub = info.find("div")
            parsed["info"] = sub.get_text(" ", strip=True) if sub else None
        parsed["id"] = item.attrs.get("data-id")
        results.append(parsed)
    return results


class Browse:
    def __init__(self, origin, proxy=None, headers=None, cookies=None):
        self.origin = origin.rstrip("/")
        self.proxy = proxy or {}
        self.headers = {**default_headers, **(headers or {})}
        self.cookies = {**default_cookies, **(cookies or {})}

    def _build_path(self, collection, category, page):
        tpl = COLLECTIONS.get(collection)
        if tpl is None:
            raise ValueError(f'Unknown collection "{collection}"')
        path = tpl.format(cat=category)
        if page and int(page) > 1:
            path = path.rstrip("/") + f"/page/{int(page)}/"
        return path

    def list(self, collection="best", category="films", page=1):
        """Return a list of catalogue items for the given collection/category/page."""
        if category not in CATEGORIES and collection != "watching":
            raise ValueError(f'Unknown category "{category}"')
        path = self._build_path(collection, category, page)
        url = self.origin + path
        r = requests.get(
            url, headers=self.headers, proxies=self.proxy,
            cookies=self.cookies, allow_redirects=True,
        )
        if not r.ok:
            raise HTTP(r.status_code, r.reason)
        return _parse_listing(r.content)
