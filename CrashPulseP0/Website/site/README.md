# CrashPulse product site

Static pages for the public product URL. They need no build step, no server code and nothing from other websites: system fonts, inline SVG, WebP screenshots. The site is separate from the Alipay experiment one level up (`shop.py`) and does not link to it.

| File | Role |
| --- | --- |
| `index.html` | Product page: what it does, how it measures, system requirements, install, pricing and availability |
| `privacy.html` | What the app and the site collect |
| `styles.css` | All styling, light and dark through `prefers-color-scheme` |
| `assets/` | App icon, favicon and example screenshots |

## Preview locally

```sh
cd CrashPulseP0/Website/site && python3 -m http.server 8765 --bind 127.0.0.1
```

Then open http://127.0.0.1:8765/.

## Before going live

Every unconfirmed business detail is wrapped in `<span class="pending">`, which renders with an orange highlight. Search for `pending` and replace each one. Then delete the `.pending` rule from `styles.css`. Nothing should be highlighted on the live site.

- Price, seller name, support email, reseller (FastSpring once approved), log retention period and the privacy page date.
- When FastSpring checkout exists, turn the Availability section into the buy section. Add the FastSpring popup or hosted checkout link there and in the header button. Add terms of sale and a refund policy page, linked from the footer. FastSpring delivers the DMG. Do not put the DMG on this server.
- Set the canonical URL and an `og:image` once the domain is known.

## Deploy

Copy the directory contents to the web root as they are. A minimal nginx server block:

```nginx
server {
    server_name crashpulse.example;
    root /srv/crashpulse-site;
    index index.html;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; frame-ancestors 'none'; base-uri 'none'";
    location /assets/ { expires 30d; }
}
```

Serve it over HTTPS. If FastSpring's popup storefront is added later, extend the Content Security Policy with the hosts FastSpring documents.

## Screenshots

`Scripts/render-site-shots.zsh` (from `CrashPulseP0/`) regenerates `assets/shots`. Events and event detail come from the Debug `--render-ui` sample scenes. Live comes from `Scripts/site-live-sample.swift`, which compiles the app sources against a fixed sample snapshot. The `--render-ui` Live scene shows the real processes of the Mac it runs on, so never publish that one. The page labels every screenshot as example data.
