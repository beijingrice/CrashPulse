from base64 import b64decode, b64encode
from io import BytesIO
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qsl, urlencode, urlsplit
from wsgiref.util import setup_testing_defaults

from alipay import Alipay
from shop import Config, handle, init


def generate_keys(root, name):
    private = root / f"{name}-private.pem"
    public = root / f"{name}-public.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
                    "-out", str(private)], capture_output=True, check=True)
    subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                   capture_output=True, check=True)
    return private, public


def signable(fields):
    return "&".join(key + "=" + value for key, value in sorted(fields.items())).encode("utf-8")


class CheckoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        merchant_private, cls.merchant_public = generate_keys(cls.root, "merchant")
        cls.alipay_private, alipay_public = generate_keys(cls.root, "alipay")
        cls.alipay = Alipay("2021000000000001", "2088000000000001", "https://example.test",
                            merchant_private, alipay_public, "sandbox")
        cls.dmg = cls.root / "CrashPulse.dmg"
        cls.dmg.write_bytes(b"fixture disk image")

    def setUp(self):
        self.config = Config(self.root / f"{self._testMethodName}.sqlite3", self.dmg, 1900, self.alipay)
        init(self.config)

    def request(self, method, path, body=b""):
        request = {}
        setup_testing_defaults(request)
        url = urlsplit(path)
        request.update(REQUEST_METHOD=method, PATH_INFO=url.path, QUERY_STRING=url.query,
                       CONTENT_LENGTH=str(len(body)), CONTENT_TYPE="application/x-www-form-urlencoded")
        request["wsgi.input"] = BytesIO(body)
        status_headers = []
        response = handle(self.config, request, lambda status, headers: status_headers.extend((status, dict(headers))))
        try:
            return int(status_headers[0].split()[0]), status_headers[1], b"".join(response)
        finally:
            if hasattr(response, "close"):
                response.close()

    def order(self):
        status, headers, _ = self.request("POST", "/orders")
        self.assertEqual(status, 303)
        url = headers["Location"]
        status, _, body = self.request("GET", url)
        self.assertEqual(status, 200)
        return url, re.search(rb"[A-F0-9]{24}", body).group().decode("ascii")

    def notification(self, reference, **overrides):
        fields = {
            "app_id": self.alipay.app_id,
            "seller_id": self.alipay.seller_id,
            "out_trade_no": reference,
            "trade_no": "2026112200000000000000000001",
            "total_amount": "19.00",
            "trade_status": "TRADE_SUCCESS",
        }
        fields.update(overrides)
        signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.alipay_private)],
                                   input=signable(fields), capture_output=True, check=True)
        return urlencode(dict(fields, sign_type="RSA2", sign=b64encode(signature.stdout).decode())).encode()

    def test_checkout_signs_amount_and_order_without_leaking_order_url(self):
        path, reference = self.order()
        status, headers, _ = self.request("GET", path + "/pay")
        self.assertEqual(status, 303)
        parsed = urlsplit(headers["Location"])
        self.assertEqual(parsed.netloc, "openapi-sandbox.dl.alipaydev.com")
        fields = dict(parse_qsl(parsed.query))
        self.assertEqual(fields["method"], "alipay.trade.page.pay")
        content = json.loads(fields["biz_content"])
        self.assertEqual(content["out_trade_no"], reference)
        self.assertEqual(content["total_amount"], "19.00")
        self.assertEqual(fields["notify_url"], "https://example.test/payment/alipay/notify")
        self.assertNotIn(path, fields["return_url"])
        signature_file = self.root / "request.sig"
        signature_file.write_bytes(b64decode(fields.pop("sign")))
        checked = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(self.merchant_public),
                                  "-signature", str(signature_file)],
                                 input=signable(fields), capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_verified_payment_unlocks_once_and_retries_safely(self):
        path, reference = self.order()
        self.assertEqual(self.request("GET", path + "/status")[2], b'{"paid":false}')
        self.assertEqual(self.request("GET", path + "/download")[0], 403)
        self.assertEqual(self.request("GET", "/payment/alipay/return?trade_status=TRADE_SUCCESS")[0], 200)
        self.assertEqual(self.request("GET", path + "/download")[0], 403)

        notification = self.notification(reference)
        for _ in range(2):
            status, _, body = self.request("POST", "/payment/alipay/notify", notification)
            self.assertEqual((status, body), (200, b"success"))
        self.assertEqual(self.request("GET", path + "/status")[2], b'{"paid":true}')
        self.assertEqual(self.request("GET", path + "/download")[2], self.dmg.read_bytes())
        self.assertEqual(self.request("GET", path + "/pay")[1]["Location"], path)

        other_path, other_reference = self.order()
        self.assertEqual(self.request("POST", "/payment/alipay/notify", self.notification(other_reference))[0], 400)
        self.assertEqual(self.request("GET", other_path + "/download")[0], 403)

    def test_rejects_bad_signatures_wrong_orders_and_mismatched_payments(self):
        path, reference = self.order()
        valid = self.notification(reference)
        for notification in (
            valid.replace(b"total_amount=19.00", b"total_amount=19.01"),
            valid + b"&total_amount=19.00",
            self.notification(reference, total_amount="18.00"),
            self.notification(reference, app_id="2021000000000002"),
            self.notification(reference, seller_id="2088000000000002"),
            self.notification("A" * 24),
        ):
            with self.subTest(notification=notification[:60]):
                self.assertEqual(self.request("POST", "/payment/alipay/notify", notification)[0], 400)
                self.assertEqual(self.request("GET", path + "/download")[0], 403)

    def test_non_success_status_keeps_download_locked(self):
        path, reference = self.order()
        for trade_status in ("WAIT_BUYER_PAY", "TRADE_CLOSED"):
            with self.subTest(trade_status=trade_status):
                notification = self.notification(reference, trade_status=trade_status)
                self.assertEqual(self.request("POST", "/payment/alipay/notify", notification)[0], 200)
                self.assertEqual(self.request("GET", path + "/download")[0], 403)
