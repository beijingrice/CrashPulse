# CrashPulse product site

Internal notes. Only `public/` goes on the web server. Everything else in this directory is tooling and launch planning, and must not be copied to the web root.

The site is separate from the Alipay experiment in `../shop.py`. It does not link to it, take payments or serve the DMG.

| Path | Role |
| --- | --- |
| `public/` | The web root: `index.html`, `privacy.html`, `404.html`, `styles.css`, `robots.txt`, `sitemap.xml`, `assets/` |
| `site.json` | Launch settings: domain, release label, support email, price and checkout link |
| `configure.py` | Writes `site.json` into the marked blocks of the pages and regenerates `robots.txt` and `sitemap.xml` |
| `check.py` | Pre-deploy check: up to date with `site.json`, links resolve, only web files, no placeholders, no outside resources |
| `og-image.svg`, `make-og.zsh` | Share image source and the script that renders `public/assets/og.png` |
| `../../Scripts/render-site-shots.zsh` | Regenerates the example screenshots in `public/assets/shots` |

## Preview

```sh
cd CrashPulseP0/Website/product-site/public && python3 -m http.server 8765 --bind 127.0.0.1
```

Open http://127.0.0.1:8765/. Canonical and share links point at the configured domain, not at the preview.

## Change a launch setting

Edit `site.json`, then run `python3 configure.py` and `python3 check.py` from this directory. Do not edit the text between `<!-- site:NAME -->` and `<!-- /site:NAME -->` by hand, because `configure.py` overwrites it.

| Setting | Current value | Effect |
| --- | --- | --- |
| `origin` | `https://crashpulse.bettercam.xyz` | Canonical URLs, `og:url`, `og:image`, `robots.txt`, `sitemap.xml` |
| `release` | `0.1.0 beta` | Availability text. The requirements table and the hero also say `0.1.0 beta` in plain HTML, so update those lines with it. |
| `supportEmail` | `null` | When set, adds a Contact link to both footers and a Contact section to the privacy page. When `null`, no contact is shown. |
| `sales.price`, `sales.checkoutUrl` | `null` | Both `null` shows "Not on sale yet". Set both to show the price and a Buy CrashPulse button that opens the checkout. `sales.checkoutNote` adds an optional line under the button. |

## Launch status (2026-11-22)

Done: product page and privacy page in English, example screenshots labeled as example data, Apple trademark notice, share image and metadata for the target domain, not-on-sale state. The verifiable release is CrashPulse 0.1.0 beta, a universal app for Apple silicon and Intel on macOS 14 or later, in a Developer ID signed and notarized DMG.

Not done: DNS, HTTPS and public access for `crashpulse.bettercam.xyz` are not configured or verified. Nothing has been deployed or submitted to FastSpring.

## Still needed before public sale

Each item names who decides and where it goes on the site.

1. **Seller and copyright holder.** The Developer ID signer is Ning Gan, but the seller of record is not decided. The footer says "© 2026 CrashPulse" until then. Once decided, update both footers and name the seller in the terms of sale.
2. **Support email.** Set `supportEmail` in `site.json`. FastSpring and customers both need a working contact address.
3. **Price and currency.** The ¥19.00 on the Alipay test page is a test value. Set `sales.price` once FastSpring pricing is set.
4. **FastSpring approval and checkout link.** FastSpring will host checkout and deliver the DMG automatically. The new-merchant application needs this product URL live. Settlement to a mainland China account, domain review and the checkout link all depend on FastSpring. Until FastSpring confirms the account, do not name it on the site. Then set `sales.checkoutUrl` and `sales.checkoutNote`, for example "Payment and download are handled by FastSpring, our online reseller." Upload the DMG to FastSpring, not to this server.
5. **Terms of sale and refund policy.** These need the seller and FastSpring's merchant-of-record terms. Add `terms.html` and `refunds.html` to `public/`, link both from the footers, and add them to `PAGES` in `configure.py` so they get canonical URLs and appear in the sitemap. Usually they cover licence scope (per user or per Mac), updates, refund window, how to request a refund, and the merchant-of-record name.
6. **Privacy page additions.** Add a purchases section that names FastSpring as merchant of record and links its privacy policy. Describe the server's access logs and retention once the Hong Kong server's logging is configured. The page now covers only what is verified: the app works offline and keeps history locally, and the pages set no cookies and load nothing from other sites. The app, the website and checkout are separate data flows, so keep them in separate sections.
7. **Version for sale.** The site says 0.1.0 beta. Change it with the first paid release.
8. **Chinese version.** Not started, waiting for the owner.

## FastSpring application materials

- Product URL: the configured `origin`, live over HTTPS.
- Product description, system requirements and install steps: on the page.
- Screenshots: on the page, labeled example data.
- Contact email, seller legal name and address, price, refund policy and terms: items 1 to 5 above.

## Deploy (when DNS and HTTPS are ready)

1. Run `python3 configure.py` and `python3 check.py`. Deploy only when the check prints that `public/` is ready.
2. Copy the contents of `public/` to the web root, for example `rsync -av --delete public/ server:/srv/crashpulse-site/`.
3. Serve it over HTTPS with a server block like this:

   ```nginx
   server {
       listen 443 ssl;
       server_name crashpulse.bettercam.xyz;
       root /srv/crashpulse-site;
       index index.html;
       add_header X-Content-Type-Options nosniff always;
       add_header Referrer-Policy strict-origin-when-cross-origin always;
       add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; frame-ancestors 'none'; base-uri 'none'" always;
       error_page 404 /404.html;
       location /assets/ { expires 30d; }
   }
   ```

   If FastSpring's popup storefront is used instead of a hosted checkout link, extend the policy with the hosts FastSpring documents.
4. Visit the HTTPS URL and confirm the page, privacy page, a missing path showing `404.html`, screenshots in light and dark, `robots.txt`, `sitemap.xml` and `assets/og.png` load. Check the share preview with a link debugger.
