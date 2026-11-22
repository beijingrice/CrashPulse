"""Alipay desktop checkout and RSA2 payment notifications."""

from base64 import b64decode, b64encode
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
from os import environ
from pathlib import Path
import re
import subprocess
from tempfile import NamedTemporaryFile
from urllib.parse import urlencode, urlsplit


GATEWAYS = {
    "production": "https://openapi.alipay.com/gateway.do",
    "sandbox": "https://openapi-sandbox.dl.alipaydev.com/gateway.do",
}
CHINA_TIME = timezone(timedelta(hours=8))


def signing_content(fields, excluded=()):
    return "&".join(f"{key}={value}" for key, value in sorted(fields.items())
                    if key not in excluded and value).encode("utf-8")


def yuan(cents):
    return f"{cents // 100}.{cents % 100:02d}"


@dataclass(frozen=True)
class Alipay:
    app_id: str
    seller_id: str
    origin: str
    private_key: Path
    public_key: Path
    environment: str

    @classmethod
    def from_env(cls):
        config = cls(
            environ["ALIPAY_APP_ID"],
            environ["ALIPAY_SELLER_ID"],
            environ["CRASHPULSE_PUBLIC_ORIGIN"].rstrip("/"),
            Path(environ["ALIPAY_APP_PRIVATE_KEY"]),
            Path(environ["ALIPAY_PLATFORM_PUBLIC_KEY"]),
            environ.get("ALIPAY_ENV", "production"),
        )
        origin = urlsplit(config.origin)
        if (origin.scheme != "https" or not origin.hostname or origin.username or origin.password
                or origin.path or origin.query or origin.fragment):
            raise ValueError("CRASHPULSE_PUBLIC_ORIGIN must be an HTTPS origin.")
        if not all(re.fullmatch(r"[0-9]{16}", value) for value in (config.app_id, config.seller_id)):
            raise ValueError("Set the Alipay app ID and seller ID.")
        if config.environment not in GATEWAYS or not all(
                key.is_file() for key in (config.private_key, config.public_key)):
            raise ValueError("Select an Alipay environment and provide both PEM key files.")
        return config

    def checkout_url(self, reference, cents):
        fields = {
            "app_id": self.app_id,
            "method": "alipay.trade.page.pay",
            "charset": "utf-8",
            "sign_type": "RSA2",
            "version": "1.0",
            "timestamp": datetime.now(CHINA_TIME).strftime("%Y-%m-%d %H:%M:%S"),
            "notify_url": self.origin + "/payment/alipay/notify",
            "return_url": self.origin + "/payment/alipay/return",
            "biz_content": json.dumps({
                "out_trade_no": reference,
                "total_amount": yuan(cents),
                "subject": "CrashPulse for macOS",
                "product_code": "FAST_INSTANT_TRADE_PAY",
                "timeout_express": "30m",
            }, separators=(",", ":")),
        }
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.private_key)],
            input=signing_content(fields), capture_output=True, timeout=5, check=True,
        )
        fields["sign"] = b64encode(signed.stdout).decode("ascii")
        return GATEWAYS[self.environment] + "?" + urlencode(fields)

    def verifies(self, fields):
        if fields.get("sign_type") != "RSA2" or not fields.get("sign"):
            return False
        try:
            signature = b64decode(fields["sign"], validate=True)
        except ValueError:
            return False
        with NamedTemporaryFile() as signature_file:
            signature_file.write(signature)
            signature_file.flush()
            checked = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(self.public_key),
                 "-signature", signature_file.name],
                input=signing_content(fields, ("sign", "sign_type")),
                capture_output=True, timeout=5,
            )
        return checked.returncode == 0
