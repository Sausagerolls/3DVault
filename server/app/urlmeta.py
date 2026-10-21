"""Pull title, description, tags, author, license and images from model hosting sites."""

import html
import json
import re
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import httpx

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
MAX_IMAGES = 6


class MetaError(Exception):
    pass


def html_to_text(s: str) -> str:
    s = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</h\d>", "\n", s or "")
    s = re.sub(r"(?i)<li[^>]*>", "- ", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s)
    return re.sub(r"\n{3,}", "\n\n", s).strip()


def fetch(url: str, thingiverse_token: str = "") -> dict:
    """Return {"name", "description", "author", "license", "tags", "images", "source_url"}."""
    host = urlparse(url).netloc.lower()
    with httpx.Client(timeout=20, follow_redirects=True, headers={"User-Agent": UA}) as client:
        if "printables.com" in host:
            return _printables(client, url)
        if "thingiverse.com" in host:
            return _thingiverse(client, url, thingiverse_token)
        if "makerworld.com" in host:
            return _makerworld(client, url)
        return _opengraph(client, url)


def _id_from(url: str, pattern: str) -> str:
    m = re.search(pattern, url)
    if not m:
        raise MetaError("Could not find a model ID in that URL")
    return m.group(1)


def _printables(client: httpx.Client, url: str) -> dict:
    pid = _id_from(url, r"/model/(\d+)")
    query = """query P($id: ID!) { print(id: $id) {
        name summary description user { publicUsername } license { name }
        tags { name } images { filePath } } }"""
    r = client.post(
        "https://api.printables.com/graphql/",
        json={"query": query, "variables": {"id": pid}},
        headers={"Content-Type": "application/json"},
    )
    r.raise_for_status()
    p = (r.json().get("data") or {}).get("print")
    if not p:
        raise MetaError("Printables returned no model")
    desc = html_to_text(p.get("description") or "") or (p.get("summary") or "")
    return {
        "name": p.get("name") or "",
        "description": desc,
        "author": (p.get("user") or {}).get("publicUsername") or "",
        "license": (p.get("license") or {}).get("name") or "",
        "tags": [t["name"] for t in p.get("tags") or []],
        "images": [f"https://media.printables.com/{i['filePath']}" for i in p.get("images") or []][:MAX_IMAGES],
        "source_url": f"https://www.printables.com/model/{pid}",
    }


def _thingiverse(client: httpx.Client, url: str, token: str) -> dict:
    tid = _id_from(url, r"thing:(\d+)")
    if not token:
        page = _opengraph(client, url)
        page["source_url"] = f"https://www.thingiverse.com/thing:{tid}"
        return page
    headers = {"Authorization": f"Bearer {token}"}
    r = client.get(f"https://api.thingiverse.com/things/{tid}", headers=headers)
    r.raise_for_status()
    t = r.json()
    imgs = client.get(f"https://api.thingiverse.com/things/{tid}/images", headers=headers).json()
    images = []
    for im in imgs if isinstance(imgs, list) else []:
        sizes = [s for s in im.get("sizes", []) if s.get("type") == "display" and s.get("size") == "large"]
        if sizes:
            images.append(sizes[0]["url"])
    return {
        "name": t.get("name") or "",
        "description": t.get("description") or html_to_text(t.get("description_html") or ""),
        "author": (t.get("creator") or {}).get("name") or "",
        "license": t.get("license") or "",
        "tags": [x["name"] for x in t.get("tags") or []],
        "images": images[:MAX_IMAGES],
        "source_url": f"https://www.thingiverse.com/thing:{tid}",
    }


def _makerworld(client: httpx.Client, url: str) -> dict:
    r = client.get(url)
    if r.status_code in (403, 503):
        raise MetaError("MakerWorld blocked the request. Fill in details by hand.")
    r.raise_for_status()
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', r.text, re.S)
    if not m:
        return _opengraph_from_html(r.text, url)
    data = json.loads(m.group(1))
    d = data.get("props", {}).get("pageProps", {}).get("design") or {}
    if not d:
        return _opengraph_from_html(r.text, url)
    pics = (d.get("designExtension") or {}).get("design_pictures") or []
    return {
        "name": d.get("title") or "",
        "description": html_to_text(d.get("details") or d.get("summary") or ""),
        "author": (d.get("designCreator") or {}).get("name") or "",
        "license": d.get("license") or "",
        "tags": d.get("tags") or [],
        "images": [p["url"] for p in pics if p.get("url")][:MAX_IMAGES] or ([d["coverUrl"]] if d.get("coverUrl") else []),
        "source_url": url.split("?")[0],
    }


def _opengraph(client: httpx.Client, url: str) -> dict:
    r = client.get(url)
    r.raise_for_status()
    return _opengraph_from_html(r.text, url)


def _opengraph_from_html(text: str, url: str) -> dict:
    def og(prop: str) -> str:
        m = re.search(
            rf'<meta[^>]+(?:property|name)=["\'](?:og:)?{prop}["\'][^>]+content=["\']([^"\']*)', text, re.I
        )
        return html.unescape(m.group(1)) if m else ""

    title = og("title") or (re.search(r"<title>(.*?)</title>", text, re.S | re.I) or [None, ""])[1]
    img = og("image")
    return {
        "name": html.unescape(title).strip(),
        "description": og("description"),
        "author": "",
        "license": "",
        "tags": [],
        "images": [img] if img else [],
        "source_url": url.split("?")[0],
    }


def download_images(urls: list[str]) -> list[Path]:
    """Download images to temp files. Caller moves them into the model."""
    out = []
    with httpx.Client(timeout=30, follow_redirects=True, headers={"User-Agent": UA}) as client:
        for i, u in enumerate(urls):
            try:
                r = client.get(u)
                r.raise_for_status()
            except httpx.HTTPError:
                continue
            ctype = r.headers.get("content-type", "")
            ext = {"image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}.get(ctype.split(";")[0], ".jpg")
            tmp = Path(tempfile.mkstemp(suffix=ext)[1])
            tmp.write_bytes(r.content)
            out.append(tmp)
    return out
