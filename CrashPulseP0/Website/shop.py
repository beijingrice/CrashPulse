"""CrashPulse checkout with automatic Alipay payment confirmation."""

import argparse
from contextlib import closing
from dataclasses import dataclass
from hashlib import sha256
from os import environ
from pathlib import Path
import re
from secrets import token_hex
import sqlite3
from urllib.parse import parse_qsl
from wsgiref.simple_server import WSGIRequestHandler, make_server
from wsgiref.util import FileWrapper

from alipay import Alipay, yuan


STYLE = Path(__file__).with_name("shop.css").read_bytes()
ORDER_SCRIPT = Path(__file__).with_name("order.js").read_bytes()
ORDER_PATH = re.compile(r"/orders/([a-f0-9]{64})(?:/(pay|status|download))?")


@dataclass(frozen=True)
class Config:
    database: Path
    dmg: Path
    price_cents: int
    alipay: Alipay

    @classmethod
    def from_env(cls):
        config = cls(
            Path(environ["CRASHPULSE_ORDERS_DB"]),
            Path(environ["CRASHPULSE_DMG"]),
            int(environ["CRASHPULSE_PRICE_CENTS"]),
            Alipay.from_env(),
        )
        if config.price_cents <= 0 or not config.dmg.is_file() or config.dmg.suffix.lower() != ".dmg":
            raise ValueError("Set a positive price and point CRASHPULSE_DMG at the release disk image.")
        return config


def connect(config):
    database = sqlite3.connect(config.database)
    database.row_factory = sqlite3.Row
    return database


def init(config):
    with closing(connect(config)) as database, database:
        database.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                token_hash TEXT PRIMARY KEY,
                reference TEXT UNIQUE NOT NULL,
                price_cents INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                transaction_id TEXT,
                confirmed_at TEXT
            )
        """)
        database.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS confirmed_transaction
            ON orders(transaction_id) WHERE confirmed_at IS NOT NULL
        """)


def respond(start, status, body=b"", mime="text/html; charset=utf-8", extra=()):
    start(status, [
        ("Content-Type", mime),
        ("Cache-Control", "private, no-store"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; "
         "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"),
        *extra,
    ])
    return body if isinstance(body, FileWrapper) else [body]


def page(start, title, content, status="200 OK"):
    return respond(start, status, f"""<!doctype html>
<html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · CrashPulse</title><link rel="stylesheet" href="/shop.css">
<main><header><a href="/">CrashPulse</a><span>macOS 14+</span></header>
<h1>{title}</h1>{content}</main></html>""".encode())


def order_page(start, order, url):
    if order["confirmed_at"]:
        return page(start, "付款已确认",
                    f'<p>打开 DMG，把 CrashPulse 拖进「应用程序」。</p>'
                    f'<a class="button" href="{url}/download">下载 CrashPulse DMG</a>')

    return page(start, "支付宝付款", f"""
<p class="amount">¥{yuan(order["price_cents"])}</p>
<p class="muted">订单 {order["reference"]}</p>
<p>支付宝收银台会在新标签页打开。到账后，本页会自动显示下载按钮。</p>
<a class="button" href="{url}/pay" target="_blank" rel="noopener noreferrer">打开支付宝收银台</a>
<p class="muted" role="status">等待付款</p>
<noscript><p>付款后，请刷新本页查看下载。</p></noscript>
<script src="/order.js" defer></script>""")


def notification_fields(request):
    length = request.get("CONTENT_LENGTH", "")
    content_type = request.get("CONTENT_TYPE", "").split(";", 1)[0]
    if (content_type != "application/x-www-form-urlencoded"
            or not re.fullmatch(r"[0-9]{1,5}", length) or not 0 < int(length) <= 16384):
        return {}
    try:
        body = request["wsgi.input"].read(int(length)).decode("utf-8")
        items = parse_qsl(body, keep_blank_values=True, strict_parsing=True, errors="strict", max_num_fields=100)
    except ValueError:
        return {}
    fields = dict(items)
    return fields if len(fields) == len(items) else {}


def payment_notification(config, request, start):
    fields = notification_fields(request)
    if fields.get("app_id") != config.alipay.app_id or fields.get("seller_id") != config.alipay.seller_id:
        return respond(start, "400 Bad Request", b"failure", "text/plain")
    if not config.alipay.verifies(fields) or not record_payment(config, fields):
        return respond(start, "400 Bad Request", b"failure", "text/plain")
    return respond(start, "200 OK", b"success", "text/plain")


def record_payment(config, fields):
    reference = fields.get("out_trade_no", "")
    transaction = fields.get("trade_no", "")
    amount = fields.get("total_amount", "")
    status = fields.get("trade_status", "")
    if (not re.fullmatch(r"[A-F0-9]{12,32}", reference) or not re.fullmatch(r"[0-9]{16,64}", transaction)
            or not re.fullmatch(r"[0-9]{1,10}(?:\.[0-9]{1,2})?", amount)):
        return False
    integer, _, fraction = amount.partition(".")
    cents = int(integer) * 100 + int(fraction.ljust(2, "0"))
    try:
        with closing(connect(config)) as database, database:
            if status in {"TRADE_SUCCESS", "TRADE_FINISHED"}:
                database.execute("""
                    UPDATE orders SET transaction_id = ?, confirmed_at = CURRENT_TIMESTAMP
                    WHERE reference = ? AND price_cents = ? AND confirmed_at IS NULL
                """, (transaction, reference, cents))
                # Check durable state for both the first notification and retries.
                return database.execute("""
                    SELECT 1 FROM orders WHERE reference = ? AND price_cents = ?
                    AND transaction_id = ? AND confirmed_at IS NOT NULL
                """, (reference, cents, transaction)).fetchone() is not None
            return status in {"WAIT_BUYER_PAY", "TRADE_CLOSED"} and database.execute("""
                SELECT 1 FROM orders WHERE reference = ? AND price_cents = ?
            """, (reference, cents)).fetchone() is not None
    except sqlite3.IntegrityError:
        return False


def file_response(start, path, mime, extra=()):
    try:
        stream = path.open("rb")
    except OSError:
        return page(start, "文件暂时无法下载", '<p>请稍后刷新页面再试。</p>', "503 Service Unavailable")
    return respond(start, "200 OK", FileWrapper(stream), mime, extra)


def handle(config, request, start):
    method, path = request["REQUEST_METHOD"], request["PATH_INFO"]
    if method == "GET" and path == "/shop.css":
        return respond(start, "200 OK", STYLE, "text/css; charset=utf-8")
    if method == "GET" and path == "/order.js":
        return respond(start, "200 OK", ORDER_SCRIPT, "text/javascript; charset=utf-8")
    if method == "POST" and path == "/payment/alipay/notify":
        return payment_notification(config, request, start)
    if method == "GET" and path == "/payment/alipay/return":
        return page(start, "支付宝收银台已返回", "<p>请回到原订单页查看付款和下载状态。</p>")
    if method == "GET" and path == "/":
        demo = '<p class="note">支付宝沙箱测试页。</p>' if config.alipay.environment == "sandbox" else ""
        return page(start, "找出哪个 App 让 Mac 忙个不停", f"""
<p>CrashPulse 在菜单栏记录持续的 CPU 异常。进程退出后，也能回看当时最可能造成负载的 App。</p>
{demo}
<p class="amount">¥{yuan(config.price_cents)}</p>
<form method="post" action="/orders"><button type="submit">购买 CrashPulse</button></form>""")

    if method == "POST" and path == "/orders":
        token = token_hex(32)
        with closing(connect(config)) as database, database:
            database.execute("INSERT INTO orders (token_hash, reference, price_cents) VALUES (?, ?, ?)",
                             (sha256(token.encode()).hexdigest(), token_hex(12).upper(), config.price_cents))
        return respond(start, "303 See Other", extra=[("Location", f"/orders/{token}")])

    match = ORDER_PATH.fullmatch(path)
    if match and method == "GET":
        token, action = match.groups()
        url = f"/orders/{token}"
        token_hash = sha256(token.encode()).hexdigest()
        with closing(connect(config)) as database:
            order = database.execute("SELECT * FROM orders WHERE token_hash = ?", (token_hash,)).fetchone()
        if order:
            if action == "status":
                body = b'{"paid":true}' if order["confirmed_at"] else b'{"paid":false}'
                return respond(start, "200 OK", body, "application/json")
            if action == "pay":
                checkout = url if order["confirmed_at"] else config.alipay.checkout_url(
                    order["reference"], order["price_cents"])
                return respond(start, "303 See Other", extra=[("Location", checkout)])
            if action == "download":
                if order["confirmed_at"]:
                    return file_response(start, config.dmg, "application/x-apple-diskimage",
                                         [("Content-Disposition", 'attachment; filename="CrashPulse.dmg"')])
                return page(start, "等待付款确认", f'<p><a href="{url}">返回订单</a></p>', "403 Forbidden")
            return order_page(start, order, url)
    return page(start, "找不到该页面", '<p><a href="/">返回首页</a></p>', "404 Not Found")


def application(request, start):
    return handle(Config.from_env(), request, start)


class PrivateRequestHandler(WSGIRequestHandler):
    def log_message(self, format, *args):
        # Order URLs are bearer credentials. Keep them out of access logs.
        pass


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--port", type=int, default=8080)
    commands.add_parser("init")
    args = parser.parse_args()
    config = Config.from_env()
    init(config)
    if args.command == "serve":
        with make_server("127.0.0.1", args.port, application, handler_class=PrivateRequestHandler) as server:
            print(f"Local preview: http://127.0.0.1:{args.port}/", flush=True)
            server.serve_forever()


if __name__ == "__main__":
    main()
