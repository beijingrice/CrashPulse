#!/usr/bin/env python3
"""Checks public/ before it is copied to the web server.

- public/ matches site.json (run configure.py if not)
- every local link, image and stylesheet exists
- only web files are in public/, no notes, scripts or config
- no launch placeholders, unconfirmed business names or payment wording leak into the pages
- nothing is loaded from another website
"""

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
PUBLIC = ROOT / "public"
WEB_TYPES = {".html", ".css", ".png", ".webp", ".svg", ".ico", ".txt", ".xml"}
# Words that must not reach visitors until the matching decision is made.
BLOCKED = [r"\bTODO\b", r"to be confirmed", r"\bpending\b", r"\bplaceholder\b", r"FastSpring", r"Alipay",
           r"支付宝", r"¥", r"\bRMB\b", r"Ning Gan", r"lorem"]

problems = []
config = json.loads((ROOT / "site.json").read_text())
origin = config["origin"].rstrip("/")

if subprocess.run([sys.executable, "-I", str(ROOT / "configure.py"), "--check"]).returncode:
    problems.append("public/ is out of date with site.json; run configure.py")

for path in sorted(PUBLIC.rglob("*")):
    if path.is_file() and (path.suffix.lower() not in WEB_TYPES or path.name.startswith(".")):
        problems.append(f"not a web file: {path.relative_to(ROOT)}")

for page in sorted(PUBLIC.rglob("*.html")) + sorted(PUBLIC.rglob("*.css")):
    text = page.read_text()
    visible = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    for word in BLOCKED:
        if re.search(word, visible, re.I):
            problems.append(f"{page.name}: contains {word!r}")
    for ref in re.findall(r'(?:href|src|srcset)="([^"]+)"|url\(([^)]+)\)', text):
        ref = next(r for r in ref if r).strip("'\"")
        parsed = urlparse(ref)
        if parsed.scheme == "mailto" or ref.startswith("#") or parsed.scheme == "data":
            continue
        if parsed.scheme or ref.startswith("//"):
            if not ref.startswith(origin + "/") and ref != (config.get("sales") or {}).get("checkoutUrl"):
                problems.append(f"{page.name}: loads or links outside the site: {ref}")
            continue
        base = PUBLIC if parsed.path.startswith("/") else page.parent
        target = (base / parsed.path.lstrip("/")).resolve()
        if parsed.path in ("", "./", "/"):
            target = PUBLIC / "index.html"
        if not target.exists():
            problems.append(f"{page.name}: missing {ref}")
    email = config.get("supportEmail")
    for found in re.findall(r"[\w.+-]+@[\w-]+\.[\w.]+", visible):
        if found != email:
            problems.append(f"{page.name}: email address not from site.json: {found}")

if not (PUBLIC / "assets" / "og.png").exists():
    problems.append("missing assets/og.png; run make-og.zsh")

for problem in problems:
    print(problem)
print("public/ is ready to copy" if not problems else f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
