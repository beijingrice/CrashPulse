# CrashPulse product site

Internal notes. Only `public/` goes on the web server. Everything else in this directory is tooling and launch planning, and must not be copied to the web root.

The site is separate from the Alipay experiment in `../shop.py`. It does not link to it, take payments or serve the DMG.

| Path | Role |
| --- | --- |
| `public/` | The web root: `index.html`, `privacy.html`, `terms.html`, `refunds.html`, `404.html`, `styles.css`, `robots.txt`, `sitemap.xml`, `assets/` |
| `site.json` | Launch settings: domain, release label, seller, support email, refund window, price, checkout link, merchant of record |
| `configure.py` | Writes `site.json` into the marked blocks of the pages and regenerates `robots.txt` and `sitemap.xml` |
| `check.py` | Pre-deploy check: up to date with `site.json`, links resolve, only web files, no placeholders, no outside resources. Also lists the settings payment approval still needs. |
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
| `release` | `0.1.0 beta` | Pricing text. The requirements table and the hero also say `0.1.0 beta` in plain HTML, so update those lines with it. |
| `seller` | `null` | Legal seller and copyright holder. Names the publisher in the Terms and replaces "CrashPulse" in every footer's copyright line. |
| `supportEmail` | `null` | Shows the address in every footer, under Pricing, in the Terms, in the Privacy Policy (with a short note on how support email is used) and in the refund steps. When `null`, no contact is shown anywhere. |
| `refundDays` | `null` | With `supportEmail`, publishes the refund policy: full refund within this many days, no reason needed, how to ask, licence ends on refund. Also adds a refund line under Pricing. Until both are set, the Refund Policy page says CrashPulse is not on sale yet. |
| `sales.price` | `null` | Free text shown large under Pricing, for example `US$9.99, one-time purchase`. Set alone, it shows the price with "Checkout is not open yet", which is enough for reviewers who need to see pricing before the checkout link exists. |
| `sales.checkoutUrl`, `sales.checkoutNote` | `null` | Adds the Buy CrashPulse button and an optional line under it. Needs `sales.price` and `merchantOfRecord.name`. |
| `merchantOfRecord.name`, `.termsUrl`, `.privacyUrl` | `null` | The payment provider that resells CrashPulse, for example Creem or FastSpring. Named in the Terms (Purchases) and the Privacy Policy (Buying CrashPulse), with links to its own terms and privacy policy. |

## Launch status (2026-11-22)

Done: product page, Privacy Policy, Terms of Service and Refund Policy in English, example screenshots labeled as example data, Apple trademark notice, share image and metadata for the target domain, not-on-sale state. The verifiable release is CrashPulse 0.1.0 beta, a universal app for Apple silicon and Intel on macOS 14 or later, in a Developer ID signed and notarized DMG.

Not done: DNS, HTTPS and public access for `crashpulse.bettercam.xyz` are not configured or verified. Nothing has been deployed or submitted to FastSpring.

## Payment provider approval checklist

The owner's screenshot of Creem's approval checklist, checked against the site on 2026-11-22. FastSpring asks for much the same.

| Requirement | Status |
| --- | --- |
| Product is live | Waiting. The site is ready to deploy; DNS and HTTPS are not set up. The app is labeled 0.1.0 beta, which a reviewer may read as not ready for production. Decide whether the first paid release keeps the beta label. |
| Own custom domain | Ready once `crashpulse.bettercam.xyz` is live. It is a subdomain of the owner's own domain, not a free hosting subdomain. |
| No false information | Ready. No reviews, testimonials or user counts. Screenshots are labeled example data. |
| Privacy Policy and Terms of Service | Pages exist and are linked from every footer. They become complete when `seller`, `supportEmail` and `merchantOfRecord` are set. |
| Product clearly visible | Ready. |
| No trademark conflicts | Not checked. Search "CrashPulse" in the USPTO, EUIPO, WIPO and China trademark databases and the Mac App Store before applying. The name may also suggest a crash reporter; the page explains what it does in its first lines. |
| Pricing is visible | Set `sales.price`. |
| Acceptable use | Ready. A local diagnostic utility with no network access. |
| Customer support email | Set `supportEmail` to a mailbox someone reads. It must also appear on receipts, which the payment provider configures. |
| Moderation API | Not applicable. CrashPulse does not generate images or video. |
| Not on prohibited list | System utilities are not on typical prohibited lists. Confirm against the provider's list when applying. |

Before applying: deploy the site, then set `seller`, `supportEmail`, `refundDays`, `sales.price` and `merchantOfRecord`, run `configure.py` and `check.py`, and deploy again. `check.py` prints which of these are still missing.

## Decisions written into the policies

The Terms and Refund Policy use common terms for a small paid Mac utility. The owner should confirm each one, ideally with a lawyer in the seller's jurisdiction, before sales open:

- **Licence scope.** Personal, non-transferable licence to use CrashPulse on any Macs the buyer owns or controls, for personal or internal business use. Change the "Your licence" section in `terms.html` for a per-Mac or per-seat licence.
- **Refunds.** Full refund within `refundDays` of purchase, no reason needed, requested by email; the licence ends on refund. 14 days is common and matches EU withdrawal periods.
- **Liability.** "As is" with no warranty, liability capped at the amount paid, consumer rights preserved.
- **Updates.** No promise of updates or support for any particular version.
- **Not included yet.** Governing law and jurisdiction, which depend on where the seller is based. Add a section to `terms.html` once the seller is known.

## Still needed before public sale

1. **Seller and copyright holder.** Set `seller`. The Developer ID signer is Ning Gan, but the seller of record is not decided.
2. **Support email.** Set `supportEmail`.
3. **Price and currency.** The ¥19.00 on the Alipay test page is a test value. Set `sales.price`.
4. **Payment provider and checkout link.** FastSpring was the plan; the owner is also looking at Creem's requirements. Whichever approves the account resells CrashPulse as merchant of record, hosts checkout and delivers the DMG. Do not name it on the site until the account is approved. Then set `merchantOfRecord` and `sales.checkoutUrl`, and upload the DMG to the provider, not to this server.
5. **Refund window.** Set `refundDays` after confirming the refund decision above.
6. **Server logs.** Describe the Hong Kong server's access logs and retention in the Privacy Policy's "This website" section once logging is configured.
7. **Version for sale.** The site says 0.1.0 beta. Change it with the first paid release.
8. **Chinese version.** Not started, waiting for the owner.

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

   If the payment provider's popup or embedded checkout is used instead of a hosted checkout link, extend the policy with the hosts the provider documents.
4. Visit the HTTPS URL and confirm the page, the Privacy, Terms and Refund pages, a missing path showing `404.html`, screenshots in light and dark, `robots.txt`, `sitemap.xml` and `assets/og.png` load. Check the share preview with a link debugger.
