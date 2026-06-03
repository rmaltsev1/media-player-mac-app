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

# Sort options applied as a `?filter=` query on a listing page. "best" is special-cased
# (it's a path segment, /{cat}/best/, not a query) and handled in _build_path.
SORTS = ["last", "popular", "soon", "watching", "best"]
SORT_FILTERS = {"last", "popular", "soon", "watching"}

# Genre slugs as they appear in HDRezka URL paths (e.g. /films/comedy/).
# Films / series / cartoons share the live-action genre set; the `animation` category
# uses its own (anime-oriented) set. Each entry is (slug, English label).
_SHARED_GENRES = [
    ("comedy", "Comedy"),
    ("drama", "Drama"),
    ("melodrama", "Melodrama"),
    ("thriller", "Thriller"),
    ("horror", "Horror"),
    ("boevik", "Action"),
    ("fantastika", "Sci-Fi"),
    ("fjentezi", "Fantasy"),
    ("detektiv", "Detective"),
    ("priklyucheniya", "Adventure"),
    ("kriminal", "Crime"),
    ("military", "War"),
    ("istoricheskiy", "History"),
    ("semeyniy", "Family"),
    ("western", "Western"),
    ("biographicheskiy", "Biography"),
    ("arthouse", "Arthouse"),
]

_ANIMATION_GENRES = [
    ("anime", "Anime"),
    ("comedy", "Comedy"),
    ("drama", "Drama"),
    ("melodrama", "Melodrama"),
    ("boevik", "Action"),
    ("fantastika", "Sci-Fi"),
    ("fjentezi", "Fantasy"),
    ("priklyucheniya", "Adventure"),
    ("detektiv", "Detective"),
    ("semeyniy", "Family"),
]

GENRES = {
    "films": _SHARED_GENRES,
    "series": _SHARED_GENRES,
    "cartoons": _SHARED_GENRES,
    "animation": _ANIMATION_GENRES,
}

# Set of valid slugs per category, for robust validation.
_GENRE_SLUGS = {cat: {slug for slug, _ in items} for cat, items in GENRES.items()}


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


def parse_similar(soup):
    """Parse the 'related/similar' block from a detail (b_post) page soup.

    HDRezka renders related titles in `.b-sidelist` with `.b-content__inline_item`-style
    entries, or under `#films_similar` / `.b-sidelist__holder` where each item is a link
    wrapping a cover <img> and a title. Returns a list of {title, url, image, category?}
    with possibly-relative URLs (the caller resolves them with abs_url)."""
    out = []
    seen = set()

    # 1) Standard inline items inside a related/sidelist container.
    containers = []
    for sel in ("#films_similar", ".b-sidelist"):
        containers.extend(soup.select(sel))
    for cont in containers:
        for item in cont.find_all(class_="b-content__inline_item"):
            try:
                parsed = SearchResult.process_item(item)
            except Exception:
                continue
            parsed["category"] = _serialize_type(parsed.get("category"))
            url = parsed.get("url")
            if url and url not in seen:
                seen.add(url)
                out.append(parsed)
    if out:
        return out

    # 2) Fallback: simple link-list layout (each <a> wraps an <img> + title text).
    holder = soup.select_one(".b-sidelist__holder") or soup.select_one("#films_similar")
    if holder:
        for a in holder.find_all("a", href=True):
            url = a["href"]
            if not url or url in seen:
                continue
            img = a.find("img")
            image = img.attrs.get("src") if img else None
            title_el = a.find(class_="title") or a.find(class_="b-sidelist__title")
            title = (title_el.get_text(strip=True) if title_el
                     else (img.attrs.get("alt") if img else None)
                     or a.get_text(" ", strip=True))
            if not title:
                continue
            seen.add(url)
            out.append({"title": title, "url": url, "image": image, "category": None})
    return out


class Browse:
    def __init__(self, origin, proxy=None, headers=None, cookies=None):
        self.origin = origin.rstrip("/")
        self.proxy = proxy or {}
        self.headers = {**default_headers, **(headers or {})}
        self.cookies = {**default_cookies, **(cookies or {})}

    def _build_path(self, collection, category, page,
                    genre=None, year=None, sort=None):
        """Build an HDRezka listing path. Robust: unknown genre/year/sort are ignored.

        Path shape:
          - homepage "watching" collection -> "/" (category/genre/year ignored)
          - genre given -> /{cat}/{genre}/
          - sort == "best" (or collection "best") -> /{cat}/best/[{year}/]
          - else -> /{cat}/
        A sort of last/popular/soon/watching is applied as a `?filter=` query.
        """
        tpl = COLLECTIONS.get(collection)
        if tpl is None:
            raise ValueError(f'Unknown collection "{collection}"')

        if collection == "watching":
            path = tpl.format(cat=category)
            if page and int(page) > 1:
                path = path.rstrip("/") + f"/page/{int(page)}/"
            return path

        # Normalize sort: an explicit sort overrides the collection's default.
        sort = sort if sort in SORTS else None
        is_best = sort == "best" or (sort is None and collection == "best")

        # Validate genre against the category's known slugs.
        valid_genre = genre if genre in _GENRE_SLUGS.get(category, set()) else None

        query = ""
        if valid_genre:
            path = f"/{category}/{valid_genre}/"
            # filter sorts still apply on a genre page; "best" doesn't (no /best/ subpath there)
            if sort in SORT_FILTERS:
                query = f"?filter={sort}"
        elif is_best:
            path = f"/{category}/best/"
            try:
                if year:
                    path += f"{int(year)}/"
            except (TypeError, ValueError):
                pass
        else:
            path = f"/{category}/"
            if sort in SORT_FILTERS:
                query = f"?filter={sort}"

        if page and int(page) > 1:
            path = path.rstrip("/") + f"/page/{int(page)}/"
        return path + query

    def list(self, collection="best", category="films", page=1,
             genre=None, year=None, sort=None):
        """Return a list of catalogue items for the given collection/category/page.

        Optional filters: `genre` (slug), `year` (int, only for the "best" listing),
        `sort` (one of SORTS). Unknown values fall back to the default behaviour."""
        if category not in CATEGORIES and collection != "watching":
            raise ValueError(f'Unknown category "{category}"')
        path = self._build_path(collection, category, page,
                                genre=genre, year=year, sort=sort)
        url = self.origin + path
        r = requests.get(
            url, headers=self.headers, proxies=self.proxy,
            cookies=self.cookies, allow_redirects=True,
        )
        if not r.ok:
            raise HTTP(r.status_code, r.reason)
        return _parse_listing(r.content)
