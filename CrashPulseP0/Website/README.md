# CrashPulse website

The store creates an order and sends the buyer to the Alipay desktop checkout (`alipay.trade.page.pay`). Alipay sends an RSA2-signed server notification to `/payment/alipay/notify`. The store verifies the signature, merchant, app, order, amount, and trade status before unlocking the notarized DMG. The buyer's private order page checks that state and displays the download automatically.

## Verify locally

Run `python3 -m unittest -v test_shop` from this directory with Python 3.9 or later and OpenSSL on PATH. The tests create temporary RSA keys and simulate Alipay notifications through the WSGI app. They use a throwaway SQLite DB and test download.

## Configure Alipay

Open a web application in Alipay Open Platform and apply for **电脑网站支付**. Configure the platform public key and merchant application private key as separate PEM files on the server. Use the public key labeled 支付宝公钥 for notification verification. The server's signing key is the merchant application private key. Restrict that file to the service account. [Alipay website-pay setup](https://aipay.alipay.com/article/3470)

Set these variables in the service environment:

| Variable | Value |
| --- | --- |
| `CRASHPULSE_PUBLIC_ORIGIN` | Public HTTPS site origin, for example `https://crashpulse.example` |
| `CRASHPULSE_PRICE_CENTS` | Final price in fen |
| `CRASHPULSE_ORDERS_DB` | SQLite path in a private writable directory |
| `CRASHPULSE_DMG` | Absolute path to the notarized release DMG outside the public directory |
| `ALIPAY_APP_ID` | Alipay web application ID |
| `ALIPAY_SELLER_ID` | The seller's Alipay merchant ID used in `seller_id` |
| `ALIPAY_APP_PRIVATE_KEY` | Path to the merchant application's private PEM key |
| `ALIPAY_PLATFORM_PUBLIC_KEY` | Path to the Alipay platform's public PEM key |
| `ALIPAY_ENV` | `sandbox` for sandbox credentials, `production` for the live merchant account |

Keep independent SQLite databases and keys for the sandbox and live store. Run `python3 shop.py init` and serve `shop:application` with the host's production WSGI server behind HTTPS. `python3 shop.py serve` is a loopback preview. Alipay needs to reach `POST /payment/alipay/notify` on the public server. Its browser return path is `/payment/alipay/return`.

Rate-limit order creation at the reverse proxy and suppress private order URLs in access logs. Before accepting real payments, add the seller identity, support contact, invoicing and refund terms, and order data notice to the purchase page. Test an Alipay sandbox purchase through the public callback before enabling live payments.
