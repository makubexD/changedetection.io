# Step-by-step: tracking an Amazon price

Click-by-click, from nothing to an alert when a product gets cheaper. Every label
below is quoted exactly as the application shows it.

> The technique in general is in [PRICE-TRACKING.md](PRICE-TRACKING.md).
> TOUS is in [GUIDE-TOUS.md](GUIDE-TOUS.md). This file is only Amazon.

**Read this first.** Amazon actively detects and blocks automated browsers. Some
listings will work for months; others will return `503`s or a CAPTCHA from the
first check and never work at all. That is not a mistake in your setup and no
setting reliably defeats it. Everything below is about maximising your odds, not
guaranteeing them.

---

## Step 0 — Prove Chrome is actually connected

```powershell
.\contrib\podman\run.ps1 -WithBrowser
```

```powershell
podman ps --pod --format "{{.Names}}  {{.Status}}"
podman exec changedetection sh -c 'echo $PLAYWRIGHT_DRIVER_URL'
podman exec changedetection python -c "import socket; socket.create_connection(('localhost',3000),5); print('browser reachable')"
```

| Command | Must print |
| --- | --- |
| 1 | `changedetection` **and** `browser-sockpuppet-chrome`, both `Up` |
| 2 | `ws://localhost:3000` |
| 3 | `browser reachable` |

**If any is wrong, stop** — send me the output.

## Step 1 — Get the canonical URL

Open the product in your own browser and copy the address. Then **strip it back to
the ASIN form**:

```
https://www.amazon.com/dp/B0XXXXXXXX
```

Delete everything from `/ref=` onwards, and any `?tag=`, `?th=`, `?psc=`
parameters. The `/dp/<ASIN>` form is stable; the long titled URLs change under you
and will silently break the watch later.

The ASIN is also on the product page under **Product details**.

## Step 2 — Add the watch

1. Open <http://localhost:5000>.
2. Paste the `/dp/` URL into the **URL** box.
3. Click **Watch**.

## Step 3 — Point this watch at Chrome ← the step people miss

1. Click the watch's **Edit** (pencil) icon.
2. On the **General** tab find **Fetch Method** and select:

   > **Playwright Chromium/Javascript via 'ws://localhost:3000'**

   Only seeing **WebDriver Chrome/Javascript**? The app has no driver URL — Step 0.

3. Click **Save**.

A watch keeps the fetcher it was created with, so until you do this it is still
fetching raw HTML.

Set it once for everything under **Settings → Fetching → Fetch Method**.

## Step 4 — Give it a real User-Agent

This matters more on Amazon than anywhere else — a default or missing UA is one of
the cheapest signals for them to block.

1. In your own browser: **F12** → **Network** tab → reload the product page →
   click the first document request → **Request Headers** → copy the
   `User-Agent` value.
2. In the watch: **Edit** → **Request** tab → **Request headers**, add:

   | Key | Value |
   | --- | --- |
   | `User-Agent` | *(the string you copied)* |

3. **Save.**

## Step 5 — Switch it to price mode

1. **Edit** → **General** → **Processor**:

   > **Re-stock & Price detection for pages with a SINGLE product**

2. **Save.**

Amazon product pages usually carry clean structured data, so this often picks up
price and stock with no filter at all. Try it before reaching for the Visual
Filter Selector.

## Step 6 — Confirm it can read the price

Click **Recheck**, wait, and look at the row. **A price appearing on the row is
the success signal.**

Blank? Go to [When no price appears](#when-no-price-appears).
`403`/`503`/CAPTCHA? Go to [When Amazon blocks you](#when-amazon-blocks-you).

## Step 7 — Set your trigger

**Edit** → **Restock & Price Detection** tab:

| Field | Set it to | Why |
| --- | --- | --- |
| **Follow price changes** | ticked | otherwise only stock changes count as a change |
| **Below price to trigger notification** | your target | the "tell me when it's cheap" trigger |
| **Above price to trigger notification** | blank | unless you want rises too |
| **Threshold (%) for price changes since the previous check** | `2` | Amazon's prices wobble by cents constantly |
| **Re-stock detection** | **In Stock only (Out Of Stock -> In Stock only)** | avoids alerts when it goes unavailable |

**Save.**

## Step 8 — Alert body that says the direction

**Edit** → **Notifications**:

```
{{watch_title}}

Now:    {{restock.price}}
Before: {{restock.previous_price}}
Stock:  {{restock.in_stock}}

{{watch_url}}
```

## Step 9 — Set a LONG interval

**Edit** → **General** → **Time between check**: **12 hours**, or daily.

On Amazon this is not politeness, it is the single biggest factor in whether the
watch keeps working. Frequent checks are the fastest way to get blocked.

---

## When no price appears

1. **Edit** → **Visual Filter Selector** tab. (Says *"Sorry, this functionality
   only works with fetchers that support Javascript and screenshots"*? You skipped
   Step 3. May need one **Recheck** first to have a screenshot.)
2. Click the price on the rendered page.
3. Check in **Filters & Triggers** that the filter caught only the price.
4. **Conditions** tab → add:

   > **Extracted number after 'Filters & Triggers'** — **less than** — your target

5. **Save**, **Recheck**.

Watch out for the **"List price"** struck-through figure and any
*"$X.XX with Subscribe & Save"* line — it is easy to capture the wrong one. Check
the preview text.

## When Amazon blocks you

Symptoms: `503`, a CAPTCHA page in the preview, or a page that renders with no
price at all.

In order of what actually helps:

1. **Raise the interval to 24 hours.** Do this first.
2. **Make sure Step 4's User-Agent is set** and matches a real browser.
3. **Wait.** Blocks are often temporary; hammering it extends them.
4. **Accept that some ASINs will not be watchable.** There is no configuration
   that fixes this.

A durable alternative for a stubborn product is to watch a price-history site's
page for that ASIN instead of Amazon directly. It updates less often, but it will
not block you.

## About `amazon.com/cart`

It requires login, so it needs your session cookie — see
[PRICE-TRACKING.md](PRICE-TRACKING.md) section 8. Be aware before you invest time
in it:

- Amazon's cart is among the most heavily defended pages on the site, and a
  headless browser hitting it from a datacenter IP is exactly the pattern they
  look for. It may simply never work.
- The cookie expires in days to weeks; when it does, the watch quietly starts
  seeing the logged-out page and reports that as a change.
- Editing your own cart fires alerts that have nothing to do with price.
- A cart shows a total: one item dropping and another rising nets to no change.

**Per-product watches are the mechanism.** Treat a cart watch as a convenience for
a shopping session you are actively running, nothing more.

## If it still does not work

| What you see | What it means |
| --- | --- |
| No **Playwright** option in Fetch Method | The app has no driver URL → Step 0 |
| Price blank, page renders fine | No structured data → *When no price appears* |
| `503` / CAPTCHA / empty page | *When Amazon blocks you* |
| Watch stuck on "Checking" | Chrome wedged: `.\contrib\podman\logs.ps1 -Browser` |
| Price detected but clearly wrong | Captured the list price or a subscription price — tighten the filter |
| Alerts every check, price unchanged | Threshold is 0 → set `2` in Step 7 |
| Worked for weeks, then stopped | Either a block (raise the interval) or the URL was not the `/dp/` form |
