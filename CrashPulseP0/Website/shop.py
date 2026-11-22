"""CrashPulse checkout with merchant-reviewed Alipay transactions."""

import argparse
from contextlib import closing
from dataclasses import dataclass
from hashlib import sha256
from html import escape
from os import environ
from pathlib import Path
import re
from secrets import token_hex
import sqlite3
from typing import Optional
from urllib.parse import parse_qs
from wsgiref.simple_server import WSGIRequestHandler, make_server
from wsgiref.util import FileWrapper


STYLE = Path(__file__).with_name("shop.css").read_bytes()
ORDER_PATH = re.compile(r"/orders/([a-f0-9]{64})(?:/(code|download))?")
TRANSACTION = re.compile(r"[0-9]{16,64}")


@dataclass(frozen=True)
class Config:
    database: Path
    dmg: Path
    price_cents: int
    merchant: str
    qr: Optional[Path] = None

    @classmethod
    def from_env(cls):
        qr_path = environ.get("CRASHPULSE_QR_PNG")
        config = cls(
            Path(environ["CRASHPULSE_ORDERS_DB"]),
            Path(environ["CRASHPULSE_DMG"]),
            int(environ["CRASHPULSE_PRICE_CENTS"]),
            environ.get("CRASHPULSE_MERCHANT", "").strip(),
            Path(qr_path) if qr_path else None,
        )
        if config.price_cents <= 0 or not config.dmg.is_file() or config.dmg.suffix.lower() != ".dmg":
            raise ValueError("Set a positive price and point CRASHPULSE_DMG at the release disk image.")
        if config.qr and (not config.qr.is_file() or config.qr.suffix.lower() != ".png" or not config.merchant):
            raise ValueError("Provide the approved merchant PNG and the displayed merchant name.")
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


def amount(cents):
    return f"¥{cents // 100}.{cents % 100:02d}"


def respond(start, status, body=b"", mime="text/html; charset=utf-8", extra=()):
    start(status, [
        ("Content-Type", mime),
        ("Cache-Control", "private, no-store"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"),
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


def order_page(start, config, order, url, error=""):
    if order["confirmed_at"]:
        return page(start, "付款已确认",
                    f'<p>打开 DMG，把 CrashPulse 拖进「应用程序」。</p>'
                    f'<a class="button" href="{url}/download">下载 CrashPulse DMG</a>')

    if order["transaction_id"]:
        payment = ""
    elif config.qr:
        payment = (f'<p>用支付宝扫描下方二维码，核对收款方 <strong>{escape(config.merchant)}</strong>。</p>'
                   '<p>如果收银台支持备注，请填写上面的订单号，方便商家核对。</p>'
                   f'<img src="{url}/code" alt="支付宝商家收款码" width="196" height="196">')
    else:
        payment = '<p class="note">测试模式。请使用模拟交易号走流程，无需付款。</p>'
    review = ('<p class="note" role="status">交易号已提交，等待商家核验。请保留本页，稍后刷新查看。</p>'
              if order["transaction_id"] else '<p>请保留本页地址，确认到账后可在这里下载。</p>')
    label = "更正交易号" if order["transaction_id"] else "提交核验"
    problem = f'<p role="alert" class="error">{error}</p>' if error else ""
    return page(start, "支付宝付款", f"""
<p class="amount">{amount(order["price_cents"])}</p>
<p class="muted">订单 {order["reference"]}</p>
{payment}{review}{problem}
<form action="{url}" method="post">
<label for="transaction">支付宝交易号</label>
<p class="muted">付款后，在支付宝账单详情里复制「订单号」。</p>
<input id="transaction" name="transaction" inputmode="numeric" autocomplete="off" required maxlength="64">
<button type="submit">{label}</button>
</form>""", "400 Bad Request" if error else "200 OK")


def transaction_from_request(request):
    length = request.get("CONTENT_LENGTH", "")
    if (request.get("CONTENT_TYPE", "").split(";")[0] != "application/x-www-form-urlencoded"
            or not length.isascii() or not length.isdigit() or len(length) > 4 or int(length) > 512):
        return ""
    text = request["wsgi.input"].read(int(length)).decode("ascii", errors="replace")
    return parse_qs(text).get("transaction", [""])[0].strip()


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
    if method == "GET" and path == "/":
        demo = "" if config.qr else '<p class="note">本地测试页。无需付款。</p>'
        return page(start, "找出哪个 App 让 Mac 忙个不停", f"""
<p>CrashPulse 在菜单栏记录持续的 CPU 异常。进程退出后，也能回看当时最可能造成负载的 App。</p>
{demo}
<p class="amount">{amount(config.price_cents)}</p>
<form method="post" action="/orders"><button type="submit">购买 CrashPulse</button></form>""")

    if method == "POST" and path == "/orders":
        token = token_hex(32)
        with closing(connect(config)) as database, database:
            database.execute("INSERT INTO orders (token_hash, reference, price_cents) VALUES (?, ?, ?)",
                             (sha256(token.encode()).hexdigest(), token_hex(6).upper(), config.price_cents))
        return respond(start, "303 See Other", extra=[("Location", f"/orders/{token}")])

    match = ORDER_PATH.fullmatch(path)
    if match and method in {"GET", "POST"}:
        token, action = match.groups()
        url = f"/orders/{token}"
        token_hash = sha256(token.encode()).hexdigest()
        with closing(connect(config)) as database, database:
            order = database.execute("SELECT * FROM orders WHERE token_hash = ?", (token_hash,)).fetchone()
            if order:
                if method == "GET" and action == "code" and config.qr:
                    return file_response(start, config.qr, "image/png")
                if method == "GET" and action == "download":
                    if order["confirmed_at"]:
                        return file_response(start, config.dmg, "application/x-apple-diskimage",
                                             [("Content-Disposition", 'attachment; filename="CrashPulse.dmg"')])
                    return page(start, "等待付款确认", f'<p><a href="{url}">返回订单</a></p>', "403 Forbidden")
                if method == "GET" and action is None:
                    return order_page(start, config, order, url)
                if method == "POST" and action is None:
                    if not order["confirmed_at"]:
                        transaction = transaction_from_request(request)
                        if not TRANSACTION.fullmatch(transaction):
                            return order_page(start, config, order, url, "请输入支付宝账单里的完整数字交易号。")
                        database.execute("""
                            UPDATE orders SET transaction_id = ?
                            WHERE token_hash = ? AND confirmed_at IS NULL
                        """, (transaction, token_hash))
                    return respond(start, "303 See Other", extra=[("Location", url)])
    return page(start, "找不到该页面", '<p><a href="/">返回首页</a></p>', "404 Not Found")


def application(request, start):
    return handle(Config.from_env(), request, start)


def pending(config):
    with closing(connect(config)) as database:
        rows = database.execute("""
            SELECT reference, transaction_id, price_cents, created_at FROM orders
            WHERE confirmed_at IS NULL AND transaction_id IS NOT NULL ORDER BY created_at
        """)
        for row in rows:
            print(row["reference"], row["transaction_id"], row["price_cents"], row["created_at"])


def confirm(config, reference, transaction, paid_cents):
    try:
        with closing(connect(config)) as database, database:
            updated = database.execute("""
                UPDATE orders SET confirmed_at = CURRENT_TIMESTAMP
                WHERE reference = ? AND transaction_id = ? AND price_cents = ? AND confirmed_at IS NULL
            """, (reference, transaction, paid_cents))
            if updated.rowcount != 1:
                raise ValueError("Order, transaction or amount does not match a pending order.")
    except sqlite3.IntegrityError as error:
        raise ValueError("Transaction already used to confirm another order.") from error


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
    commands.add_parser("pending")
    review = commands.add_parser("confirm")
    review.add_argument("reference")
    review.add_argument("--transaction", required=True)
    review.add_argument("--paid-cents", required=True, type=int)
    args = parser.parse_args()
    config = Config.from_env()
    init(config)
    if args.command == "serve":
        with make_server("127.0.0.1", args.port, application, handler_class=PrivateRequestHandler) as server:
            print(f"Local preview: http://127.0.0.1:{args.port}/", flush=True)
            server.serve_forever()
    elif args.command == "pending":
        pending(config)
    elif args.command == "confirm":
        try:
            confirm(config, args.reference, args.transaction, args.paid_cents)
        except ValueError as error:
            parser.exit(1, f"{error}\n")
        print("Download unlocked.")


if __name__ == "__main__":
    main()
