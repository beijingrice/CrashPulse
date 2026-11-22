#!/usr/bin/env python3
"""Checks public/ before it is copied to the web server.

Fails when:
- site.json has a malformed value, or a Buy link without everything live checkout needs
  (configure.live_problems: confirmed publisher, support email, price, chosen refund policy,
  Creem Buyer Terms and Privacy Notice links, a valid Creem payment link)
- public/ is out of date with site.json (run configure.py)
- a local link, image or stylesheet is missing
- public/ holds anything that is not a web file, such as notes, scripts or config
- launch placeholders or unconfirmed business wording reach the pages
- a page loads or links anything outside the site other than the configured checkout and
  Creem's published terms and privacy notice

It then lists what Creem's approval checklist still needs. Those do not fail the check while
there is no Buy link, because pre-sale and price-only review pages can go live without them.
"""

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.dont_write_bytecode = True
import configure  # noqa: E402

PUBLIC = ROOT / "public"
WEB_TYPES = {".html", ".css", ".png", ".webp", ".svg", ".ico", ".txt", ".xml"}
# Words that must not reach visitors. A configured publisher or copyright holder is exempt.
BLOCKED = [r"\bTODO\b", r"to be confirmed", r"\bpending\b", r"\bplaceholder\b", r"FastSpring", r"Alipay",
           r"支付宝", r"¥", r"\bRMB\b", r"Ning Gan", r"lorem", r"example\.(com|org)"]

problems = []
config = json.loads((ROOT / "site.json").read_text())
problems += [f"site.json: {p}" for p in configure.shape_problems(config)]
sales = config.get("sales") or {}
if sales.get("checkoutUrl"):
    problems += [f"live checkout blocked: {p}" for p in configure.live_problems(config)]

if not problems and subprocess.run([sys.executable, "-I", str(ROOT / "configure.py"), "--check"]).returncode:
    problems.append("public/ is out of date with site.json; run configure.py")

for path in sorted(PUBLIC.rglob("*")):
    if path.is_file() and (path.suffix.lower() not in WEB_TYPES or path.name.startswith(".")):
        problems.append(f"not a web file: {path.relative_to(ROOT)}")

configured_names = " ".join(filter(None, [(config.get("publisher") or {}).get("name"), config.get("copyrightHolder")]))
blocked = [word for word in BLOCKED if not re.search(word, configured_names, re.I)]
origin = str(config.get("origin", "")).rstrip("/")
creem = config.get("creem") or {}
allowed_outside = {url for url in [sales.get("checkoutUrl"), creem.get("buyerTermsUrl"), creem.get("privacyUrl")] if url}
email = config.get("supportEmail")

for page in sorted(PUBLIC.rglob("*.html")) + sorted(PUBLIC.rglob("*.css")):
    text = page.read_text()
    visible = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    for word in blocked:
        if re.search(word, visible, re.I):
            problems.append(f"{page.name}: contains {word!r}")
    for ref in re.findall(r'(?:href|src|srcset)="([^"]+)"|url\(([^)]+)\)', text):
        ref = next(r for r in ref if r).strip("'\"").replace("&amp;", "&")
        parsed = urlparse(ref)
        if parsed.scheme in ("mailto", "data") or ref.startswith("#"):
            continue
        if parsed.scheme or ref.startswith("//"):
            if not ref.startswith(origin + "/") and ref not in allowed_outside:
                problems.append(f"{page.name}: loads or links outside the site: {ref}")
            continue
        base = PUBLIC if parsed.path.startswith("/") else page.parent
        target = PUBLIC / "index.html" if parsed.path in ("", "./", "/") else (base / parsed.path.lstrip("/")).resolve()
        if not target.exists():
            problems.append(f"{page.name}: missing {ref}")
    for found in re.findall(r"[\w.+-]+@[\w-]+\.[\w.]+", visible):
        if found != email:
            problems.append(f"{page.name}: email address not from site.json: {found}")

if not (PUBLIC / "assets" / "og.png").exists():
    problems.append("missing assets/og.png; run make-og.zsh")

for problem in problems:
    print(problem)
print("public/ is ready to copy" if not problems else f"{len(problems)} problem(s)")

gaps = configure.approval_gaps(config) if not sales.get("checkoutUrl") else []
if gaps:
    print("Not yet ready for Creem approval or live checkout. Still needed in site.json:")
    for gap in gaps:
        print(f"  - {gap}")
elif not problems:
    print("site.json has everything Creem approval and live checkout need")
sys.exit(1 if problems else 0)
