#!/usr/bin/env python3
"""Applies site.json to the static pages in public/.

Every value that depends on a launch decision lives in site.json. This script rewrites the
blocks between <!-- site:NAME --> and <!-- /site:NAME --> markers and regenerates robots.txt
and sitemap.xml, so public/ stays a plain directory that can be copied to any web root.
A value left null never shows up as a placeholder: the pages fall back to wording that is
true without it.

The site has three sales states:
  pre-sale  sales.price is null. Pricing says "Not on sale yet".
  review    sales.price is set, sales.checkoutUrl is null. The price is visible for payment
            provider review and checkout is marked as not open.
  live      sales.checkoutUrl is set. Allowed only when every value in live_problems() is
            confirmed and valid. Otherwise this script refuses and writes nothing.

    python3 configure.py            # apply site.json
    python3 configure.py --check    # fail if public/ is out of date with site.json
"""

import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlparse

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
PAGES = {
    "index.html": ("/", "CrashPulse: find out what kept your Mac busy",
                   "CrashPulse is a menu bar app for macOS 14 or later. It records sustained CPU activity, "
                   "names the app most likely responsible, and shows live CPU and CPU power per app."),
    "privacy.html": ("/privacy.html", "Privacy Policy: CrashPulse",
                     "What the CrashPulse app, this website, support email and checkout collect."),
    "terms.html": ("/terms.html", "Terms of Service: CrashPulse",
                   "The terms for using the CrashPulse app and this website."),
    "refunds.html": ("/refunds.html", "Refund Policy: CrashPulse",
                     "How refunds for CrashPulse work."),
}
EMAIL = re.compile(r"[^@\s<>\"]+@[^@\s<>\"]+\.[A-Za-z]{2,}")
# Creem's published documents, read 2026-11-22. Buyers must be given the Buyer Terms before
# they pay (Creem Merchant Terms 3.8), and Creem processes checkout data under its Privacy Notice.
CREEM_BUYER_TERMS = "https://www.creem.io/buyer-terms"
CREEM_PRIVACY = "https://www.creem.io/privacy"
CREEM_ENTITY = "Armitage Labs OÜ, Estonia"
# The only checkout format confirmed in Creem's docs: a live product payment link.
CREEM_PAYMENT_LINK = re.compile(r"/payment/prod_[A-Za-z0-9]+")
CREEM_LINK_PARAMS = re.compile(r"discount_code|theme|metadata\[[A-Za-z0-9_]+\]")
REFUND_MODES = ("voluntary-window", "statutory-only")
e = html.escape


def creem_checkout_problem(url):
    """Why url is not an accepted Creem checkout link, or None if it is."""
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "creem.io":
        return "must start with https://creem.io/"
    if not CREEM_PAYMENT_LINK.fullmatch(parsed.path):
        return "must be a Creem product payment link like https://creem.io/payment/prod_..."
    if parsed.fragment or parsed.params:
        return "must not contain a fragment"
    for key, _ in parse_qsl(parsed.query, keep_blank_values=True):
        if not CREEM_LINK_PARAMS.fullmatch(key):
            return f"has an unsupported query parameter {key!r}"
    return None


def shape_problems(config):
    """Values that are malformed whatever the sales state."""
    problems = []
    origin = str(config.get("origin", "")).rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query:
        problems.append("origin must look like https://example.com with no path")
    email = config.get("supportEmail")
    if email is not None and not (isinstance(email, str) and EMAIL.fullmatch(email)):
        problems.append("supportEmail must be an email address or null")
    publisher = config.get("publisher") or {}
    if not isinstance(publisher.get("confirmed", False), bool):
        problems.append("publisher.confirmed must be true or false")
    refund = config.get("refundPolicy") or {}
    mode, days = refund.get("mode"), refund.get("voluntaryWindowDays")
    if mode is not None and mode not in REFUND_MODES:
        problems.append(f"refundPolicy.mode must be null or one of {', '.join(REFUND_MODES)}")
    if mode == "voluntary-window" and not (isinstance(days, int) and not isinstance(days, bool) and days >= 1):
        problems.append("refundPolicy.voluntaryWindowDays must be a whole number of days for voluntary-window")
    if mode != "voluntary-window" and days is not None:
        problems.append("refundPolicy.voluntaryWindowDays is only used with mode voluntary-window")
    logs = config.get("webServerLogs")
    if logs is not None and not (isinstance(logs, dict) and logs.get("recorded") and logs.get("retention")):
        problems.append("webServerLogs must be null or give both recorded and retention, as verified on the server")
    return problems


def live_problems(config):
    """What stops a Buy link from going live. Empty means checkout may be published."""
    problems = []
    publisher = config.get("publisher") or {}
    if not (publisher.get("name") and publisher.get("confirmed") is True):
        problems.append("publisher.name is not set and confirmed (publisher.confirmed: true)")
    if not (isinstance(config.get("supportEmail"), str) and EMAIL.fullmatch(config["supportEmail"])):
        problems.append("supportEmail is missing or invalid")
    sales = config.get("sales") or {}
    if not sales.get("price"):
        problems.append("sales.price is missing")
    if (config.get("refundPolicy") or {}).get("mode") not in REFUND_MODES:
        problems.append("refundPolicy.mode is not chosen (voluntary-window or statutory-only)")
    creem = config.get("creem") or {}
    if creem.get("buyerTermsUrl") != CREEM_BUYER_TERMS:
        problems.append(f"creem.buyerTermsUrl must be {CREEM_BUYER_TERMS}")
    if creem.get("privacyUrl") != CREEM_PRIVACY:
        problems.append(f"creem.privacyUrl must be {CREEM_PRIVACY}")
    url = sales.get("checkoutUrl")
    if not url:
        problems.append("sales.checkoutUrl is missing")
    elif creem_checkout_problem(url):
        problems.append(f"sales.checkoutUrl {creem_checkout_problem(url)}")
    return problems


def approval_gaps(config):
    """Values Creem's approval checklist needs, reported but not enforced before going live."""
    gaps = [p for p in live_problems(config) if not p.startswith("sales.checkoutUrl")]
    if not config.get("copyrightHolder"):
        gaps.append("copyrightHolder is not set (footers say © CrashPulse until then)")
    return gaps


def load():
    config = json.loads((ROOT / "site.json").read_text())
    problems = shape_problems(config)
    if (config.get("sales") or {}).get("checkoutUrl"):
        problems += live_problems(config)
    if problems:
        print("site.json was not applied. Fix these first:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        sys.exit(1)
    config["origin"] = config["origin"].rstrip("/")
    return config


def state(config):
    sales = config.get("sales") or {}
    if sales.get("checkoutUrl"):
        return "live"
    return "review" if sales.get("price") else "pre-sale"


def mail(address):
    return f'<a href="mailto:{e(address)}">{e(address)}</a>'


def link(text, url):
    return f'<a href="{e(url)}">{e(text)}</a>'


def blocks(config, page):
    origin = config["origin"]
    path, title, description = PAGES[page]
    email = config.get("supportEmail")
    publisher = config.get("publisher") or {}
    publisher_name = publisher.get("name") if publisher.get("confirmed") is True else None
    refund = config.get("refundPolicy") or {}
    mode, days = refund.get("mode"), refund.get("voluntaryWindowDays")
    release = e(config["release"])
    sales = config.get("sales") or {}
    creem = config.get("creem") or {}
    buyer_terms = link("Buyer Terms", creem.get("buyerTermsUrl") or CREEM_BUYER_TERMS)
    creem_privacy = link("Privacy Notice", creem.get("privacyUrl") or CREEM_PRIVACY)
    now = state(config)
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
    out["footer"] = (f'      <span>&copy; 2026 {e(config.get("copyrightHolder") or "CrashPulse")}</span>\n'
                     '      <nav aria-label="Site">\n' + "\n".join(links) + "\n      </nav>" + trademarks)

    if page == "index.html":
        lines = []
        if now == "pre-sale":
            lines.append('        <p class="status">Not on sale yet</p>')
            lines.append(f'        <p class="prose">The current release is CrashPulse {release}, signed and notarized by Apple. '
                         'Pricing and a way to buy will appear here when sales open.</p>')
        else:
            lines.append(f'        <p class="price">{e(sales["price"])}</p>')
            lines.append(f'        <p class="prose">CrashPulse {release} for macOS 14 or later, on Apple silicon and Intel Macs. '
                         'Signed and notarized by Apple.</p>')
            if now == "live":
                lines.append(f'        <a class="button" href="{e(sales["checkoutUrl"])}">Buy CrashPulse</a>')
                lines.append(f'        <p class="fine">Checkout is run by Creem, which resells CrashPulse as merchant of record '
                             f'and handles payment, invoices and sales tax. By buying, you also agree to Creem&rsquo;s {buyer_terms}.</p>')
            else:
                lines.append('        <p class="status">Checkout is not open yet</p>')
                lines.append(f'        <p class="fine">When it opens, checkout will be run by Creem, which will resell CrashPulse as '
                             f'merchant of record and handle payment, invoices and sales tax under Creem&rsquo;s {buyer_terms}.</p>')
        details = []
        if mode == "voluntary-window" and email:
            details.append(f'Refunds within {days} days of purchase, as described in the <a href="refunds.html">refund policy</a>.')
        if email:
            details.append(f"Questions before or after buying: {mail(email)}.")
        if details:
            lines.append('        <p class="fine">' + " ".join(details) + "</p>")
        out["sales"] = "\n".join(lines)

    if page == "privacy.html":
        logs = config.get("webServerLogs")
        out["privacy-logs"] = (
            f"        <p>The server that hosts this website records {e(logs['recorded'])} for each request, and keeps "
            f"these logs for {e(logs['retention'])}.</p>") if logs else ""
        out["privacy-support"] = (
            "        <h2>Support email</h2>\n"
            f"        <p>If you write to {mail(email)}, we receive your email address and whatever you include in "
            "your message, and use them to answer you.</p>") if email else ""
        if now == "live":
            out["privacy-checkout"] = (
                "        <p>Checkout is run by Creem (" + e(CREEM_ENTITY) + "), which resells CrashPulse as merchant of "
                "record. The payment and billing details you enter at checkout go to Creem, not to this website, and "
                f"Creem processes them under its {creem_privacy}.</p>")
        else:
            out["privacy-checkout"] = (
                "        <p>CrashPulse is not on sale yet, and this website does not take payments. When sales open, "
                "checkout will be run by Creem (" + e(CREEM_ENTITY) + "), which will resell CrashPulse as merchant of "
                f"record and process the payment and billing details you enter under its {creem_privacy}.</p>")
        out["privacy-contact"] = (
            f"        <h2>Contact</h2>\n        <p>Questions about privacy can be sent to {mail(email)}.</p>") if email else ""

    if page == "terms.html":
        party = (f"CrashPulse is published by {e(publisher_name)} (&ldquo;we&rdquo;, &ldquo;us&rdquo;)."
                 if publisher_name else "In these terms, &ldquo;we&rdquo; and &ldquo;us&rdquo; mean the publisher of CrashPulse.")
        out["terms-party"] = (f"        <p>These terms cover your use of the CrashPulse app and this website. {party}</p>")
        if now == "live":
            sale = (f"You buy CrashPulse from Creem ({e(CREEM_ENTITY)}), which sells it as reseller and merchant of "
                    "record. Creem processes your payment, issues your invoice, and calculates and collects sales tax, "
                    "VAT and other transaction taxes.")
        else:
            sale = (f"CrashPulse is not on sale yet. When it is, you will buy it from Creem ({e(CREEM_ENTITY)}), which "
                    "will sell it as reseller and merchant of record. Creem will process your payment, issue your "
                    "invoice, and calculate and collect sales tax, VAT and other transaction taxes.")
        out["terms-purchases"] = (
            f"        <p>{sale} Your purchase is also governed by Creem&rsquo;s {buyer_terms}, which take precedence "
            "over these terms where the two conflict.</p>\n"
            "        <p>We remain responsible for delivering CrashPulse to you after purchase, for the app working as "
            "described, and for support.</p>")
        out["terms-contact"] = (
            f"        <h2>Contact</h2>\n        <p>Questions about these terms can be sent to {mail(email)}.</p>"
        ) if email else ""

    if page == "refunds.html":
        if mode in REFUND_MODES and email:
            if mode == "voluntary-window":
                ours = (f"        <h2>Our voluntary refund</h2>\n"
                        f"        <p>On top of those rights, you can ask for a full refund within {days} days of your "
                        "purchase, for any reason. This voluntary refund does not replace or shorten your rights under law.</p>")
            else:
                ours = ("        <h2>Refunds beyond the law</h2>\n"
                        "        <p>We do not offer refunds beyond those your consumer rights give you. If CrashPulse does "
                        "not work as described, contact support so we can help.</p>")
            out["refund-policy"] = (
                "        <h2>Your rights under the law</h2>\n"
                "        <p>If you are a consumer, the law of your country may give you rights, for example remedies if "
                "CrashPulse does not work as described. Nothing in this policy limits them. If you live in the EU, EEA or "
                f"UK, Creem&rsquo;s {buyer_terms} explain your right of withdrawal and when it ends for digital products "
                "delivered right away.</p>\n"
                f"{ours}\n"
                "        <h2>How to ask for a refund</h2>\n"
                f"        <p>Write to {mail(email)} from the email address you used at checkout, and include the order "
                "number from your receipt if you have it. We check your request against this policy and the law that "
                "applies to you. If the refund is approved, Creem, which processed your payment, refunds it to your "
                "original payment method through its system.</p>\n"
                f"        <p>If we cannot resolve your request, Creem&rsquo;s {buyer_terms} explain how to contact Creem.</p>\n"
                "        <h2>After a refund</h2>\n"
                "        <p>Your licence ends when the refund is issued. Please quit CrashPulse and move it to the Trash.</p>")
        else:
            out["refund-policy"] = (
                "        <p>CrashPulse is not on sale yet, so there is nothing to refund. The refund policy that applies "
                "to purchases will be published on this page before checkout opens. It will not limit any rights you "
                "have under consumer protection law.</p>")
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
    print(f"sales state: {state(config)}")


if __name__ == "__main__":
    main()
