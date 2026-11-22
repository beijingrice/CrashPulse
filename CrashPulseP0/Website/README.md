# CrashPulse website

A small storefront for the notarized disk image. The buyer submits an Alipay transaction number and keeps the private order page. The merchant reviews the actual transaction in the Alipay merchant dashboard before unlocking the DMG. Order status and approval live in SQLite.

## Local preview

From the repository root, use Python 3.9 or later.

```sh
cd CrashPulseP0/Website
mkdir -p ../.build/website-preview
export CRASHPULSE_ORDERS_DB="$PWD/../.build/website-preview/orders.sqlite3"
export CRASHPULSE_DMG="$PWD/../.build/dmg-20261122/CrashPulse-0.1.0-beta.dmg"
export CRASHPULSE_PRICE_CENTS=1900
python3 shop.py serve
```

Open `http://127.0.0.1:8080/`. The sample price is for testing. With no QR image configured, the page displays a test message and accepts mock transaction numbers for local verification.

## Review a payment

Run the commands on the host with the same environment as the website.

```sh
python3 shop.py pending
python3 shop.py confirm ORDER_REFERENCE --transaction VERIFIED_ALIPAY_TRANSACTION --paid-cents VERIFIED_AMOUNT_IN_FEN
```

Use the merchant ledger to verify the full transaction number, successful payment status, amount, payee, and payment time against the pending order. Match the order remark if the Alipay payment page supports remarks. For an ambiguous payment, resolve the match with the buyer before approving. The submitted transaction number is a lookup reference. One merchant transaction can unlock one order. The buyer refreshes the private order page to download.

## Deploy on the Hong Kong server

- Confirm with Alipay that the merchant's product and QR code support remote checkout for software sold on a website. Set the real price, `CRASHPULSE_MERCHANT` to the displayed payee name, and `CRASHPULSE_QR_PNG` to an approved PNG file. Keep the demo database separate from live orders.
- Store the QR, SQLite DB, and signed DMG outside any publicly served directory. Give the web service read access to the two files and write access to its SQLite data directory. Use `python3 shop.py init` to prepare the database, then serve the WSGI callable `shop:application` with the host's production WSGI server behind HTTPS.
- Rate-limit order creation at the reverse proxy and suppress full order URLs in access logs. The URL grants access to the order and its download. Keep the SQLite DB backed up and restrict approval to the server operator.
- Before accepting real payments, add the final seller identity, support contact, invoicing and refund terms, and order data notice to the purchase page. Verify the live flow with the approved Alipay merchant product.
