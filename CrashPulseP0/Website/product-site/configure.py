#!/usr/bin/env python3
"""Applies site.json to the static pages in public/.

Every value that depends on launch decisions (domain, seller, support email, price,
checkout link, refund window, merchant of record) lives in site.json. This script
rewrites the blocks between <!-- site:NAME --> and <!-- /site:NAME --> markers and
regenerates robots.txt and sitemap.xml, so public/ stays a plain directory that can be
copied to any web root. A value left null never shows up as a placeholder: the pages
fall back to wording that is true without it.

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
    "privacy.html": ("/privacy.html", "Privacy Policy: CrashPulse",
                     "What the CrashPulse app, this website and purchases collect, and what they don't."),
    "terms.html": ("/terms.html", "Terms of Service: CrashPulse",
                   "The terms for using the CrashPulse app and this website."),
    "refunds.html": ("/refunds.html", "Refund Policy: CrashPulse",
                     "How refunds for CrashPulse work."),
}
EMAIL = re.compile(r"[^@\s<>\"]+@[^@\s<>\"]+\.[A-Za-z]{2,}")
e = html.escape


def https_or_none(value, name):
    if value is not None and urlparse(value).scheme != "https":
        sys.exit(f"site.json: {name} must be an https URL or null")


def load():
    config = json.loads((ROOT / "site.json").read_text())
    origin = config["origin"].rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query:
        sys.exit("site.json: origin must look like https://example.com with no path")
    config["origin"] = origin
    email = config.get("supportEmail")
    if email is not None and not EMAIL.fullmatch(email):
        sys.exit("site.json: supportEmail must be an email address or null")
    days = config.get("refundDays")
    if days is not None and (not isinstance(days, int) or days < 1):
        sys.exit("site.json: refundDays must be a whole number of days or null")
    sales = config.setdefault("sales", {})
    https_or_none(sales.get("checkoutUrl"), "sales.checkoutUrl")
    if sales.get("checkoutUrl") and not sales.get("price"):
        sys.exit("site.json: set sales.price before sales.checkoutUrl")
    merchant = config.setdefault("merchantOfRecord", {})
    https_or_none(merchant.get("termsUrl"), "merchantOfRecord.termsUrl")
    https_or_none(merchant.get("privacyUrl"), "merchantOfRecord.privacyUrl")
    if sales.get("checkoutUrl") and not merchant.get("name"):
        sys.exit("site.json: name the merchantOfRecord before adding a checkout link")
    return config


def mail(address):
    return f'<a href="mailto:{e(address)}">{e(address)}</a>'


def linked(name, url):
    return f'<a href="{e(url)}">{e(name)}</a>' if url else e(name)


def blocks(config, page):
    origin = config["origin"]
    path, title, description = PAGES[page]
    email = config.get("supportEmail")
    seller = config.get("seller")
    days = config.get("refundDays")
    release = e(config["release"])
    sales = config["sales"]
    merchant = config["merchantOfRecord"]
    merchant_name = merchant.get("name")
    out = {}

    out["meta"] = "\n".join([
        f'  <link rel="canonical" href="{e(origin + path)}">',
        '  <meta property="og:type" content="website">',
        '  <meta property="og:site_name" content="CrashPulse">',
        f'  <meta property="og:title" content="{e(title)}">',
        f'  <meta property="og:description" content="{e(description)}">',
        f'  <meta property="og:url" content="{e(origin + path)}">',
        f'  <meta property="og:image" content="{e(origin)}/assets/og.png">',
        '  <meta property="og:image:width" content="1200">',
        '  <meta property="og:image:height" content="630">',
        '  <meta property="og:image:alt" content="CrashPulse: a CPU trace with one sustained event highlighted in red.">',
        '  <meta name="twitter:card" content="summary_large_image">',
    ])

    links = [] if page == "index.html" else ['        <a href="./">Home</a>']
    links += ['        <a href="privacy.html">Privacy</a>',
              '        <a href="terms.html">Terms</a>',
              '        <a href="refunds.html">Refunds</a>']
    if email:
        links.append(f"        {mail(email)}")
    trademarks = ('\n      <p class="trademarks">Mac, macOS and Apple silicon are trademarks of Apple Inc. '
                  'Other app names in example screenshots belong to their owners.</p>') if page == "index.html" else ""
    out["footer"] = (f'      <span>&copy; 2026 {e(seller or "CrashPulse")}</span>\n'
                     f'      <nav aria-label="Site">\n' + "\n".join(links) + "\n      </nav>" + trademarks)

    if page == "index.html":
        lines = []
        if sales.get("price"):
            lines.append(f'        <p class="price">{e(sales["price"])}</p>')
            lines.append(f'        <p class="prose">CrashPulse {release} for macOS 14 or later, on Apple silicon and Intel Macs. '
                         'Signed and notarized by Apple.</p>')
            if sales.get("checkoutUrl"):
                lines.append(f'        <a class="button" href="{e(sales["checkoutUrl"])}">Buy CrashPulse</a>')
                if sales.get("checkoutNote"):
                    lines.append(f'        <p class="fine">{e(sales["checkoutNote"])}</p>')
            else:
                lines.append('        <p class="status">Checkout is not open yet</p>')
        else:
            lines.append('        <p class="status">Not on sale yet</p>')
            lines.append(f'        <p class="prose">The current release is CrashPulse {release}, signed and notarized by Apple. '
                         'Pricing and a way to buy will appear here when sales open.</p>')
        details = []
        if days:
            details.append(f'Refunds within {days} days of purchase, as described in the <a href="refunds.html">refund policy</a>.')
        if email:
            details.append(f"Questions before or after buying: {mail(email)}.")
        if details:
            lines.append('        <p class="fine">' + " ".join(details) + "</p>")
        out["sales"] = "\n".join(lines)

    if page == "privacy.html":
        if merchant_name:
            policy = f" under its own {linked('privacy policy', merchant.get('privacyUrl'))}"
            out["privacy-purchases"] = (
                f"        <p>Purchases are processed by {e(merchant_name)}, which acts as the reseller and merchant of record. "
                f"When you buy CrashPulse you give your payment and billing details to {e(merchant_name)}, not to this website, "
                f"and {e(merchant_name)} handles them{policy}.</p>\n"
                f"        <p>{e(merchant_name)} shares your name, email address, country and order details with us so we can "
                "deliver your purchase, answer support requests and process refunds. We do not receive your card details.</p>")
        else:
            out["privacy-purchases"] = (
                "        <p>CrashPulse is not on sale yet, and this website does not take payments. When sales open, this "
                "section will explain who processes purchases and what information they receive.</p>")
        out["privacy-contact"] = (
            "        <h2>Email</h2>\n"
            f"        <p>If you write to {mail(email)}, we use your message and email address only to reply to you, "
            "and keep them as long as we need to help you.</p>\n"
            "        <h2>Contact</h2>\n"
            f"        <p>Questions about privacy can be sent to {mail(email)}.</p>") if email else ""

    if page == "terms.html":
        party = (f"CrashPulse is published by {e(seller)} (&ldquo;we&rdquo;, &ldquo;us&rdquo;)." if seller
                 else "In these terms, &ldquo;we&rdquo; and &ldquo;us&rdquo; mean the publisher of CrashPulse.")
        out["terms-party"] = (f"        <p>These terms cover your use of the CrashPulse app and this website. {party} "
                              "By downloading, installing or using CrashPulse, you agree to them.</p>")
        if merchant_name:
            terms = f" under its own {linked('terms', merchant.get('termsUrl'))}"
            out["terms-purchases"] = (
                f"        <p>Purchases are processed by {e(merchant_name)}, which acts as the reseller and merchant of record "
                f"for your order. {e(merchant_name)} handles payment, sales tax or VAT, invoices and delivery of the download"
                f"{terms}. The price, including any tax, is shown at checkout before you pay.</p>")
        else:
            out["terms-purchases"] = (
                "        <p>CrashPulse is not on sale yet. When it is, the price and the company that processes payment will "
                "be shown before you pay, and this section will name them.</p>")
        out["terms-contact"] = (
            f"        <h2>Contact</h2>\n        <p>Questions about these terms can be sent to {mail(email)}.</p>"
        ) if email else ""

    if page == "refunds.html":
        if days and email:
            processor = (f"{e(merchant_name)}, which processed your payment, returns the money to the original payment method."
                         if merchant_name else "The money goes back to the original payment method.")
            out["refund-policy"] = (
                f"        <p>If CrashPulse is not right for you, ask for a refund within {days} days of your purchase and "
                "you will get your money back in full. You do not need to give a reason.</p>\n"
                "        <h2>How to ask</h2>\n"
                f"        <p>Write to {mail(email)} from the email address you used at checkout, and include your order "
                f"number if you have it. {processor} Most banks show the refund within 5 to 10 business days.</p>\n"
                "        <h2>After a refund</h2>\n"
                "        <p>Your licence ends when the refund is issued. Please quit CrashPulse and move it to the Trash.</p>\n"
                "        <h2>Your rights</h2>\n"
                "        <p>This policy does not limit any rights you have under the consumer protection laws of your country.</p>")
        else:
            out["refund-policy"] = (
                "        <p>CrashPulse is not on sale yet, so there is nothing to refund. The refund policy that applies to "
                "purchases will be published on this page before sales open.</p>")
    return out


def render(config):
    out = {}
    for page in PAGES:
        text = (PUBLIC / page).read_text()
        for name, body in blocks(config, page).items():
            pattern = re.compile(rf"(?P<indent>[ \t]*)<!-- site:{name} -->.*?<!-- /site:{name} -->", re.S)
            if not pattern.search(text):
                sys.exit(f"{page}: missing <!-- site:{name} --> block")

            def fill(match, name=name, body=body):
                indent = match["indent"]
                inner = f"\n{body}\n" if body else "\n"
                return f"{indent}<!-- site:{name} -->{inner}{indent}<!-- /site:{name} -->"
            text = pattern.sub(fill, text)
        out[PUBLIC / page] = text
    origin = config["origin"]
    out[PUBLIC / "robots.txt"] = f"User-agent: *\nAllow: /\n\nSitemap: {origin}/sitemap.xml\n"
    urls = "".join(f"  <url><loc>{e(origin + path)}</loc></url>\n" for path, _, _ in PAGES.values())
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
