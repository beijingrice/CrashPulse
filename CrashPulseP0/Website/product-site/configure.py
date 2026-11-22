#!/usr/bin/env python3
"""Applies site.json to the static pages in public/.

Every value that depends on launch decisions (domain, support email, price and
checkout link) lives in site.json. This script rewrites the blocks between
<!-- site:NAME --> and <!-- /site:NAME --> markers and regenerates robots.txt and
sitemap.xml, so public/ stays a plain directory that can be copied to any web root.

    python3 configure.py            # apply site.json
    python3 configure.py --check    # fail if public/ is out of date with site.json
"""

import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
PAGES = {
    "index.html": ("/", "CrashPulse: find out what kept your Mac busy",
                   "CrashPulse is a menu bar app for macOS 14 or later. It records sustained CPU activity, "
                   "names the app most likely responsible, and shows live CPU and CPU power per app."),
    "privacy.html": ("/privacy.html", "Privacy: CrashPulse",
                     "What the CrashPulse app and this website collect, and what they don't."),
}


def load():
    config = json.loads((ROOT / "site.json").read_text())
    origin = config["origin"].rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query:
        sys.exit("site.json: origin must look like https://example.com with no path")
    email = config.get("supportEmail")
    if email is not None and not re.fullmatch(r"[^@\s<>\"]+@[^@\s<>\"]+\.[A-Za-z]{2,}", email):
        sys.exit("site.json: supportEmail must be an email address or null")
    sales = config.get("sales") or {}
    url = sales.get("checkoutUrl")
    if url is not None and urlparse(url).scheme != "https":
        sys.exit("site.json: sales.checkoutUrl must be an https URL or null")
    if bool(sales.get("price")) != bool(url):
        sys.exit("site.json: set sales.price and sales.checkoutUrl together, or leave both null")
    config["origin"] = origin
    return config


def blocks(config, page):
    e = html.escape
    origin = config["origin"]
    path, title, description = PAGES[page]
    meta = "\n".join([
        f'  <link rel="canonical" href="{e(origin + path)}">',
        f'  <meta property="og:type" content="website">',
        f'  <meta property="og:site_name" content="CrashPulse">',
        f'  <meta property="og:title" content="{e(title)}">',
        f'  <meta property="og:description" content="{e(description)}">',
        f'  <meta property="og:url" content="{e(origin + path)}">',
        f'  <meta property="og:image" content="{e(origin)}/assets/og.png">',
        f'  <meta property="og:image:width" content="1200">',
        f'  <meta property="og:image:height" content="630">',
        f'  <meta property="og:image:alt" content="CrashPulse: a CPU trace with one sustained event highlighted in red.">',
        f'  <meta name="twitter:card" content="summary_large_image">',
    ])
    email = config.get("supportEmail")
    sales = config.get("sales") or {}
    release = e(config["release"])
    if sales.get("checkoutUrl"):
        note = f'\n        <p class="fine">{e(sales["checkoutNote"])}</p>' if sales.get("checkoutNote") else ""
        sales_html = (f'        <p class="price">{e(sales["price"])}</p>\n'
                      f'        <p class="prose">CrashPulse {release} for macOS 14 or later, signed and notarized by Apple.</p>\n'
                      f'        <a class="button" href="{e(sales["checkoutUrl"])}">Buy CrashPulse</a>{note}')
    else:
        sales_html = (f'        <p class="status">Not on sale yet</p>\n'
                      f'        <p class="prose">The current release is CrashPulse {release}, signed and notarized by Apple. '
                      f'Pricing and a way to buy will appear here when sales open.</p>')
    contact = f'        <a href="mailto:{e(email)}">Contact</a>' if email else ""
    privacy_contact = (f'        <h2>Contact</h2>\n        <p>Questions about privacy can be sent to '
                       f'<a href="mailto:{e(email)}">{e(email)}</a>.</p>') if email else ""
    return {"meta": meta, "sales": sales_html, "contact-link": contact, "privacy-contact": privacy_contact}


def render(config):
    out = {}
    for page in PAGES:
        text = (PUBLIC / page).read_text()
        for name, body in blocks(config, page).items():
            pattern = re.compile(rf"(?P<indent>[ \t]*)<!-- site:{name} -->.*?<!-- /site:{name} -->", re.S)
            def fill(match):
                indent = match["indent"]
                inner = f"\n{body}\n" if body else "\n"
                return f"{indent}<!-- site:{name} -->{inner}{indent}<!-- /site:{name} -->"
            text = pattern.sub(fill, text)
        out[PUBLIC / page] = text
    origin = config["origin"]
    out[PUBLIC / "robots.txt"] = f"User-agent: *\nAllow: /\n\nSitemap: {origin}/sitemap.xml\n"
    urls = "".join(f"  <url><loc>{html.escape(origin + path)}</loc></url>\n" for path, _, _ in PAGES.values())
    out[PUBLIC / "sitemap.xml"] = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                                   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                                   f"{urls}</urlset>\n")
    return out


def main():
    config = load()
    rendered = render(config)
    stale = [path for path, text in rendered.items() if not path.exists() or path.read_text() != text]
    if "--check" in sys.argv:
        for path in stale:
            print(f"out of date: {path.relative_to(ROOT)}")
        sys.exit(1 if stale else 0)
    for path in stale:
        path.write_text(rendered[path])
        print(f"updated {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
