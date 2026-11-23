#!/usr/bin/env python3
"""Runs configure.py and check.py against site.json scenarios in a temporary copy.

The repository's own site.json and public/ are never changed. Run from anywhere:

    python3 test_config.py
"""

import copy
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPLETE = {
    "publisher": {"name": "Test Publisher Ltd", "confirmed": True},
    "copyrightHolder": "Test Publisher Ltd",
    "supportEmail": "support@crashpulse-test.invalid",
    "refundPolicy": {"mode": "voluntary-window", "voluntaryWindowDays": 14},
    "sales": {"price": "US$1.00, one-time purchase", "checkoutUrl": "https://creem.io/payment/prod_TEST123"},
    "download": None,
}
results = []


def tree_hash(public):
    digest = hashlib.sha256()
    for path in sorted(public.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(public).as_posix().encode() + path.read_bytes())
    return digest.hexdigest()


def scenario(name, edit, expect_apply, expect_check, page_checks=(), message=None):
    with tempfile.TemporaryDirectory() as tmp:
        site = Path(tmp) / "product-site"
        shutil.copytree(HERE, site, ignore=shutil.ignore_patterns("__pycache__"))
        config = json.loads((site / "site.json").read_text())
        edit(config)
        (site / "site.json").write_text(json.dumps(config, indent=2))
        before = tree_hash(site / "public")
        applied = subprocess.run([sys.executable, "-I", str(site / "configure.py")], capture_output=True, text=True)
        checked = subprocess.run([sys.executable, "-I", str(site / "check.py")], capture_output=True, text=True)
        failures = []
        if (applied.returncode == 0) != expect_apply:
            failures.append(f"configure exit {applied.returncode}, expected {'0' if expect_apply else 'non-zero'}")
        if not expect_apply and tree_hash(site / "public") != before:
            failures.append("configure changed public/ although it refused")
        if (checked.returncode == 0) != expect_check:
            failures.append(f"check exit {checked.returncode}, expected {'0' if expect_check else 'non-zero'}")
        if message and message not in applied.stderr + applied.stdout + checked.stdout:
            failures.append(f"output does not mention {message!r}")
        for page, text, present in page_checks:
            html = (site / "public" / page).read_text()
            if (text in html) != present:
                failures.append(f"{page} {'lacks' if present else 'contains'} {text!r}")
        results.append((name, failures, applied.stderr.strip() or checked.stdout.strip()))


def setter(*pairs):
    def edit(config):
        for path, value in pairs:
            node = config
            *parents, leaf = path.split(".")
            for key in parents:
                node = node.setdefault(key, {})
            node[leaf] = value
    return edit


def complete(*pairs):
    def edit(config):
        for key, value in copy.deepcopy(COMPLETE).items():
            config[key] = value
        setter(*pairs)(config)
    return edit


NO_BUY = ("index.html", "Buy CrashPulse", False)
DOWNLOAD = 'href="assets/CrashPulse-0.1.dmg" download>Download for Mac'
scenario("draft (repository site.json): free download", lambda c: None, True, True,
         [("index.html", DOWNLOAD, True), ("index.html", '<p class="price">Free</p>', True),
          ("index.html", "Not on sale yet", False), NO_BUY, ("refunds.html", "not on sale yet", True)])
scenario("pre-sale without a download", setter(("download", None)), True, True,
         [("index.html", "Not on sale yet", True), ("index.html", 'href="#features">See what it does', True),
          ("index.html", "Download", False), NO_BUY])
scenario("download file missing from public/", setter(("download", "assets/CrashPulse-9.9.dmg")), True, False,
         message="missing assets/CrashPulse-9.9.dmg")
for value in ["https://example.net/CrashPulse.dmg", "../CrashPulse.dmg", "assets/CrashPulse.zip", "  "]:
    scenario(f"invalid download = {value!r}", setter(("download", value)), False, False, message="download must be")
scenario("download with a price", setter(("sales.price", "US$1.00")), False, False, message="cannot be combined")
scenario("review: price only", setter(("sales.price", "US$1.00"), ("download", None)), True, True,
         [("index.html", "US$1.00", True), ("index.html", "Checkout is not open yet", True), ("index.html", "https://www.creem.io/buyer-terms", True), NO_BUY])
scenario("live link with nothing else set", setter(
    ("publisher", {"name": None, "confirmed": False}),
    ("supportEmail", None),
    ("refundPolicy", {"mode": None, "voluntaryWindowDays": None}),
    ("sales", {"price": None, "checkoutUrl": "https://creem.io/payment/prod_TEST123"}),
), False, False, message="publisher.name is not set")
for field, value, message in [
    ("publisher.name", None, "publisher.name"),
    ("publisher.confirmed", False, "publisher.name"),
    ("supportEmail", None, "supportEmail"),
    ("sales.price", None, "sales.price"),
    ("refundPolicy.mode", None, "refundPolicy.mode"),
    ("creem.buyerTermsUrl", None, "creem.buyerTermsUrl"),
    ("creem.privacyUrl", None, "creem.privacyUrl"),
]:
    edit = complete((field, value)) if field != "refundPolicy.mode" else complete(("refundPolicy", {"mode": None, "voluntaryWindowDays": None}))
    scenario(f"live, missing {field}", edit, False, False, message=message)
for field, value, message in [
    ("supportEmail", "support@", "supportEmail"),
    ("publisher.confirmed", "yes", "publisher.confirmed"),
    ("refundPolicy.voluntaryWindowDays", 0, "voluntaryWindowDays"),
    ("refundPolicy.mode", "store-credit", "refundPolicy.mode"),
    ("creem.buyerTermsUrl", "https://www.creem.io/terms", "creem.buyerTermsUrl"),
    ("creem.privacyUrl", "http://www.creem.io/privacy", "creem.privacyUrl"),
    ("sales.checkoutUrl", "http://creem.io/payment/prod_TEST123", "https://creem.io/"),
    ("sales.checkoutUrl", "https://www.creem.io/payment/prod_TEST123", "https://creem.io/"),
    ("sales.checkoutUrl", "https://creem.io.example.net/payment/prod_TEST123", "https://creem.io/"),
    ("sales.checkoutUrl", "https://creem.io/checkout/prod_TEST123", "payment link"),
    ("sales.checkoutUrl", "https://creem.io/payment/prod_TEST123?redirect=https://evil.test", "unsupported query"),
    ("sales.checkoutUrl", "https://creem.io/payment/prod_TEST123#x", "fragment"),
    ("webServerLogs", {"recorded": "IP address"}, "webServerLogs"),
    ("publisher.name", "   ", "publisher.name"),
    ("publisher.name", " \t\n", "publisher.name"),
    ("sales.price", "  ", "sales.price"),
    ("sales.price", "\t", "sales.price"),
    ("copyrightHolder", "  ", "copyrightHolder"),
]:
    scenario(f"live, invalid {field} = {value!r}", complete((field, value)), False, False, message=message)
scenario("review: whitespace-only price", setter(("sales.price", "   ")), False, False, message="sales.price")
scenario("pre-sale: whitespace-only publisher.name", setter(("publisher", {"name": "  ", "confirmed": True})), False, False,
         message="publisher.name")
scenario("complete live config, voluntary refund window", complete(), True, True, [
    ("index.html", 'href="https://creem.io/payment/prod_TEST123">Buy CrashPulse', True),
    ("index.html", "merchant of record", True),
    ("index.html", "https://www.creem.io/buyer-terms", True),
    ("terms.html", "published by Test Publisher Ltd", True),
    ("terms.html", "You buy CrashPulse from Creem", True),
    ("privacy.html", "https://www.creem.io/privacy", True),
    ("refunds.html", "within 14 days", True),
    ("refunds.html", "original payment method through its system", True),
    ("index.html", "&copy; 2026 Test Publisher Ltd", True),
])
scenario("complete live config, statutory-only refunds",
         complete(("refundPolicy", {"mode": "statutory-only", "voluntaryWindowDays": None})), True, True,
         [("refunds.html", "beyond those your consumer rights give you", True), ("refunds.html", "within 14 days", False)])
scenario("complete live config with a payment link query",
         complete(("sales.checkoutUrl", "https://creem.io/payment/prod_TEST123?theme=dark")), True, True)

failed = 0
for name, failures, output in results:
    print(f"{'PASS' if not failures else 'FAIL'}  {name}")
    for failure in failures:
        failed += 1
        print(f"        {failure}")
        print("        " + output.replace("\n", "\n        "))
print(f"{len(results) - sum(1 for _, f, _ in results if f)} of {len(results)} scenarios passed")
sys.exit(1 if failed else 0)
