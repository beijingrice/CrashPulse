# CrashPulse product site

Internal notes. Only `public/` goes on the web server. Everything else in this directory is tooling and launch planning, and must not be copied to the web root.

The site is separate from the Alipay experiment in `../shop.py`. It does not link to it, take payments or serve the DMG.

| Path | Role |
| --- | --- |
| `public/` | The web root: `index.html`, `privacy.html`, `terms.html`, `refunds.html`, `404.html`, `styles.css`, `robots.txt`, `sitemap.xml`, `assets/` |
| `site.json` | Launch settings: domain, release, publisher, copyright holder, support email, refund policy, web server logs, price, Creem checkout link and Creem document links |
| `configure.py` | Validates `site.json`, writes it into the marked blocks of the pages, and regenerates `robots.txt` and `sitemap.xml`. Refuses to write anything if a Buy link is configured without everything live checkout needs. |
| `check.py` | Pre-deploy check. Fails on malformed settings, an incomplete live checkout, stale pages, missing files, non-web files, placeholders, or outside resources. Lists what Creem approval still needs. |
| `test_config.py` | Runs configure and check against 33 site.json scenarios (pre-sale, price-only review, each missing, invalid or whitespace-only live field, complete live configs) in a temporary copy |
| `og-image.svg`, `make-og.zsh` | Share image source and the script that renders `public/assets/og.png` |
| `../../Scripts/render-site-shots.zsh` | Regenerates the example screenshots in `public/assets/shots` |

## Preview

```sh
cd CrashPulseP0/Website/product-site/public && python3 -m http.server 8765 --bind 127.0.0.1
```

Open http://127.0.0.1:8765/. Canonical and share links point at the configured domain, not at the preview.

## Change a launch setting

Edit `site.json`, then run `python3 configure.py` and `python3 check.py` from this directory. After changing either script, also run `python3 test_config.py`. Do not edit the text between `<!-- site:NAME -->` and `<!-- /site:NAME -->` by hand, because `configure.py` overwrites it.

### Sales states

| State | site.json | What visitors see |
| --- | --- | --- |
| Pre-sale (now) | `sales.price` null | Pricing says "Not on sale yet". Terms and Privacy say Creem will run checkout when sales open. Refund Policy says there is nothing to refund yet. |
| Price-only review | `sales.price` set, `sales.checkoutUrl` null | The price, "Checkout is not open yet", and a note that Creem will run checkout under its Buyer Terms. For Creem's reviewers, who need to see pricing before the checkout link exists. |
| Live | `sales.checkoutUrl` set | Buy CrashPulse button, Creem merchant-of-record disclosure and Buyer Terms link before payment (Creem Merchant Terms 3.7 and 3.8), and the full refund policy. |

Live checkout fails closed. `configure.py` refuses to write anything, and `check.py` fails, unless all of these are set and valid:

- `publisher.name` as a nonblank string, with `publisher.confirmed: true`
- `supportEmail`
- `sales.price` as a nonblank string
- `refundPolicy.mode`, either `voluntary-window` with `voluntaryWindowDays`, or `statutory-only`
- `creem.buyerTermsUrl` exactly `https://www.creem.io/buyer-terms`, and `creem.privacyUrl` exactly `https://www.creem.io/privacy`
- `sales.checkoutUrl` as a Creem product payment link: `https://creem.io/payment/prod_…`, optionally with `discount_code`, `theme` or `metadata[…]` parameters. It is the only checkout format Creem's docs confirm. Other hosts, `www.creem.io`, API checkout session URLs and test-mode links are rejected until verified.

### Settings

| Setting | Current value | Effect |
| --- | --- | --- |
| `origin` | `https://crashpulse.bettercam.xyz` | Canonical URLs, share metadata, `robots.txt`, `sitemap.xml` |
| `release` | `0.1.0 beta` | Pricing text. The requirements table and the hero also say `0.1.0 beta` in plain HTML, so update those lines with it. |
| `publisher.name`, `publisher.confirmed` | `null`, `false` | The party that publishes CrashPulse, named in the Terms only when confirmed. Until then the Terms say "the publisher of CrashPulse". |
| `copyrightHolder` | `null` | The copyright line in every footer. Separate from the publisher. Until set, footers say "© 2026 CrashPulse". |
| `supportEmail` | `null` | Shown in every footer, under Pricing, in the Terms, in the Privacy Policy's support email and contact sections, and in the refund steps. When null, no contact is shown anywhere. |
| `refundPolicy.mode`, `.voluntaryWindowDays` | `null`, `null` | `voluntary-window`: a voluntary full refund within N days on top of statutory rights. `statutory-only`: no refunds beyond what the law gives. Either way the page states statutory rights separately, points EU, EEA and UK buyers to the withdrawal rules in Creem's Buyer Terms, sends requests to support, and says Creem refunds approved requests to the original payment method through its system. Published only with `supportEmail`. |
| `webServerLogs` | `null` | Set to `{"recorded": "...", "retention": "..."}` only after reading the Hong Kong server's real log format and rotation. Adds one sentence to the Privacy Policy. When null, the policy says nothing about server logs. |
| `sales.price` | `null` | Free text, for example `US$9.99, one-time purchase`. |
| `sales.checkoutUrl` | `null` | The Creem payment link. Turns the site live; see the rules above. |
| `creem.buyerTermsUrl`, `creem.privacyUrl` | Creem's published URLs | Linked from Pricing, Terms, Privacy and Refunds. These are Creem's public documents, not business decisions. |

## Launch status (2026-11-22)

Done: product page, Privacy Policy, Terms of Service and Refund Policy in English, aligned with Creem's Merchant Terms V2.0, Buyer Terms (effective 16.11.2026) and Privacy Notice V2.0, example screenshots labeled as example data, Apple trademark notice, share image and metadata for the target domain, not-on-sale state. The verifiable release is CrashPulse 0.1.0 beta, a universal app for Apple silicon and Intel on macOS 14 or later, in a Developer ID signed and notarized DMG.

Not done: DNS, HTTPS and public access for `crashpulse.bettercam.xyz` are not configured or verified. Nothing has been deployed, and no Creem account settings were changed.

## How the policies follow Creem's documents

Read on 2026-11-22. Creem's documents change; re-read them before going live and when Creem announces a new version.

- **Roles.** Creem (Armitage Labs OÜ, Estonia) is reseller and merchant of record. It processes payment, issues the invoice and handles transaction taxes (Merchant Terms 3.2, 3.3, 17.1). CrashPulse stays responsible for delivery, the product working as described, and support (3.4, 3.5, 17.1). The Terms say both.
- **Before payment.** Buyers must learn that Creem is merchant of record and receive the current Buyer Terms before paying (3.7, 3.8). Pricing in live mode does both, and the Terms say the Buyer Terms take precedence where they conflict (3.8, Buyer Terms 3.3.3).
- **Refunds.** Buyers contact the merchant first (Buyer Terms 9.1). The merchant decides eligibility and requests the refund in the Creem dashboard (Merchant Terms 11.2). Creem processes all refunds (11.1) and may refund on its own where law or card rules require (11.3). The Refund Policy sends requests to support, applies the published policy, and says Creem refunds to the original payment method. It promises no bank timeline and does not say Creem hosts the download.
- **Statutory rights.** The Terms keep consumer remedies, required updates and non-excludable liability intact. EU, EEA and UK withdrawal is described by Creem's Buyer Terms section 8, which the Refund Policy points to instead of restating.
- **Changes to the Terms.** A change does not reach back to earlier purchases, and buyers are told about material changes where we can reach them. When the Terms change materially, first copy the current `terms.html` to `public/terms-YYYY-MM-DD.html` (the old effective date), link it from a "Previous versions" line on the new page, and add it to `PAGES` in `configure.py`.
- **Privacy.** App data, website, support email and checkout are separate sections. The checkout section says only what is verified: payment and billing details go to Creem under its Privacy Notice, not to this website.

## Not verified, kept out of the public pages

- **What Creem shares with us about buyers.** Creem's Privacy Notice lists merchants as recipients (4.1) and mentions analytics from buyer name, email and IP (3.1.5), but does not list the fields a merchant receives per order. Check the Creem dashboard and webhook payloads, then add a sentence to the Privacy Policy's checkout section.
- **Web server logs.** Fields and retention depend on the Hong Kong server's nginx and logrotate settings. Read them on the server, then set `webServerLogs`.
- **Support email handling.** How long support email is kept depends on the mailbox. Add a retention sentence once the mailbox is chosen.
- **Delivery.** How a buyer receives the DMG after paying (Creem file delivery, a licence email, or a download link from us) is not decided. The Terms only say we are responsible for delivery. Describe it once it is set up in Creem.
- **Refund eligibility wording.** Creem's Merchant Terms 11.2 give the merchant the eligibility decision. Buyer Terms 9.3 say Creem handles refunds based on the eligibility criteria in the product terms. The Refund Policy states those criteria explicitly so both readings agree.
- **EU withdrawal at checkout.** Buyer Terms 8.2 end the withdrawal right when a consumer agrees to immediate delivery of digital content. Whether Creem's checkout collects that consent should be confirmed in a test checkout.
- **Other Creem URL formats.** Test-mode payment links and API checkout session URLs (`POST https://api.creem.io/v1/checkouts` returns a `checkout_url`) were not documented in the pages read. Extend `creem_checkout_problem` in `configure.py` only after seeing real URLs.

## Creem approval checklist

From the owner's screenshot, checked against the site on 2026-11-22.

| Requirement | Status |
| --- | --- |
| Product is live | Waiting. The site is ready to deploy; DNS and HTTPS are not set up. The app is labeled 0.1.0 beta, which a reviewer may read as not ready for production. Decide whether the first paid release keeps the beta label. |
| Own custom domain | Ready once `crashpulse.bettercam.xyz` is live. Creem only allows sites disclosed to it (Merchant Terms 6.4.3), so list this domain in the account. |
| No false information | Ready. No reviews, testimonials or user counts. Screenshots are labeled example data. |
| Privacy Policy and Terms of Service | Pages exist, aligned with Creem, linked from every footer. They name the publisher and show contact details once `publisher` and `supportEmail` are set. |
| Product clearly visible | Ready. |
| No trademark conflicts | Not checked. Search "CrashPulse" in the USPTO, EUIPO, WIPO and China trademark databases and the Mac App Store before applying. |
| Pricing is visible | Set `sales.price`. Price-only review mode shows it without a Buy link. |
| Acceptable use | Ready. A local diagnostic utility with no network access. |
| Customer support email | Set `supportEmail`. It must also appear on receipts, which is configured in Creem. |
| Moderation API | Not applicable. CrashPulse does not generate images or video. |
| Not on prohibited list | System utilities are not on typical prohibited lists. Confirm against Creem's list when applying. |

## Decisions still needed from the owner

1. **Publisher**, and whether it is a person or a company. Set `publisher.name` and `publisher.confirmed`. Creem also needs the country of establishment, tax residency and VAT number (Merchant Terms 4.3).
2. **Copyright holder** for the footers. Set `copyrightHolder`.
3. **Support email.** Set `supportEmail` to a mailbox someone reads.
4. **Price and currency.** The ¥19.00 on the Alipay test page is a test value. Set `sales.price`.
5. **Refund policy.** Choose `voluntary-window` with a number of days (14 is common) or `statutory-only`.
6. **Licence scope** in the Terms: currently any Mac the buyer owns or controls, for personal or internal business use. Change the "Your licence" section for per-Mac or per-seat licences.
7. **Governing law** for the Terms, which depends on where the publisher is based. Not included yet. Creem's own documents follow Estonian law.
8. **Delivery method** after purchase, then describe it in the Terms.
9. **Server logs**, once the server is set up: set `webServerLogs`.
10. **Version for sale.** The site says 0.1.0 beta. Change it with the first paid release.
11. **Chinese version.** Not started, waiting for the owner.

Before applying to Creem: deploy the site, set items 1 to 5, run `configure.py` and `check.py`, and deploy again. Before going live: add the Creem payment link as `sales.checkoutUrl`, make a test purchase in Creem's test mode, then deploy.

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

   The Buy button links to Creem's hosted payment page, so the policy needs no Creem hosts. If Creem's embedded checkout is ever used instead, extend the policy with the hosts Creem documents.
4. Visit the HTTPS URL and confirm the page, the Privacy, Terms and Refund pages, a missing path showing `404.html`, screenshots in light and dark, `robots.txt`, `sitemap.xml` and `assets/og.png` load. Check the share preview with a link debugger.
