# Step-by-step: tracking a TOUS price

Click-by-click, from nothing to an alert when a bag gets cheaper. Every label
below is quoted exactly as the application shows it.

> The technique in general is in [PRICE-TRACKING.md](PRICE-TRACKING.md).
> Amazon is in [GUIDE-AMAZON.md](GUIDE-AMAZON.md). This file is only TOUS.

---

## Step 0 — Prove Chrome is actually connected

TOUS builds its product pages with JavaScript. Without a browser the price is not
merely wrong, it is **absent**. Do this before anything else.

```powershell
.\contrib\podman\run.ps1 -WithBrowser
```

Then run all three of these and compare against the expected column:

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

**If any of the three is wrong, stop here** — nothing below will work. Send me
the output.

## Step 1 — Find the product URL

Open <https://www.tous.com/pe-es/carteras/bandoleras/c/486> in your own browser
and **click into the specific bag you want**.

Copy that URL — the one with the product name in it. It will look roughly like
`https://www.tous.com/pe-es/.../p/XXXXXXXXX`.

**Do not use the `/c/486` URL.** That is a category listing. It changes when any
bag on it sells out, when the grid reorders, when a badge appears — you would get
alerts constantly and none of them would be about your price.

## Step 2 — Add the watch

1. Open <http://localhost:5000>.
2. Paste the **product** URL into the **URL** box at the top.
3. Click **Watch**.

The watch appears in the list. Ignore whatever it says for now.

## Step 3 — Point this watch at Chrome ← the step people miss

1. Click the watch's **Edit** (pencil) icon.
2. Stay on the **General** tab.
3. Find **Fetch Method**. Select:

   > **Playwright Chromium/Javascript via 'ws://localhost:3000'**

   If that option does not exist and you only see **WebDriver Chrome/Javascript**,
   the app never received the driver URL — go back to Step 0.

4. Click **Save**.

**Nothing works until you do this.** A watch keeps whatever fetcher it was created
with, so it is still fetching raw HTML — and TOUS's raw HTML has no price in it.

To avoid repeating this for every bag: **Settings → Fetching → Fetch Method** →
select the same Playwright option → **Save**. New watches then inherit it.

## Step 4 — Switch it to price mode

1. **Edit** the watch again.
2. On the **General** tab find **Processor** and select:

   > **Re-stock & Price detection for pages with a SINGLE product**

3. Click **Save**.

A new **Restock & Price Detection** tab now exists on the edit screen.

> **Shortcut:** if the app noticed product data by itself, the watch row shows
> *"Switch to Restock & Price watch mode?"* with a **Yes** button. That does this
> step for you.

## Step 5 — Confirm it can actually read the price

1. Back on the watch list, click **Recheck** on that watch.
2. Wait for it to finish, then look at the row.

**A price in `S/` appearing on the row is the success signal.** If you see one,
go to Step 6.

If the price is blank, jump to [When no price appears](#when-no-price-appears).

## Step 6 — Set your trigger

**Edit** the watch → **Restock & Price Detection** tab:

| Field | Set it to | Why |
| --- | --- | --- |
| **Follow price changes** | ticked | otherwise only stock changes count as a change at all |
| **Below price to trigger notification** | your target, e.g. `249` | this is the "tell me when it gets cheap" trigger |
| **Above price to trigger notification** | leave blank | only if you also want to hear about rises |
| **Threshold (%) for price changes since the previous check** | `2` | ignores cent-level jitter and rounding noise |
| **Re-stock detection** | **In Stock only (Out Of Stock -> In Stock only)** | stops alerts for a sold-out item whose price "changed" to nothing |

**Save.**

## Step 7 — Make the alert say which way it moved

**Edit** → **Notifications**, and use this as the body:

```
{{watch_title}}

Now:    {{restock.price}}
Before: {{restock.previous_price}}
Stock:  {{restock.in_stock}}

{{watch_url}}
```

Set it once globally under **Settings → Notifications** and every price watch
inherits it.

## Step 8 — Set a sane interval

**Edit** → **General** → **Time between check**: **6 hours** is right for retail.

Checking every few minutes does not find the drop meaningfully sooner, and it is
the most reliable way to get your IP blocked.

## Step 9 — Repeat per bag

One watch per bag. Each gets its own target price, and each alert names the actual
item. This beats one category watch in every respect.

---

## When no price appears

TOUS does not always publish machine-readable product data. Extract the price by
hand:

1. **Edit** the watch → **Visual Filter Selector** tab.
   - If it says *"Sorry, this functionality only works with fetchers that support
     Javascript and screenshots"*, you skipped Step 3.
   - It may need one **Recheck** first to have a screenshot to show you.
2. **Click the price** on the rendered page. That fills in a filter in
   **Filters & Triggers**.
3. Open **Filters & Triggers** and check the filter caught *only* the price —
   `S/ 249.00`, not the whole product block.
4. Go to the **Conditions** tab and add one rule:

   > **Extracted number after 'Filters & Triggers'** — **less than** — `249`

5. **Save**, then **Recheck**.

This is the manual equivalent of Step 6: it fires only when the number is below
your target.

## TOUS-specific notes

- **Currency.** Peruvian soles (`S/`). If a price is detected but looks 100x or
  1/100 off, the decimal separator was misread — tighten the filter in
  Filters & Triggers to the exact price element.
- **"Was" prices.** Discounted items show the old price struck through. If your
  filter grabbed that one you will track the wrong number. Check the preview text.
- **The cart page** (`/pe-es/cart`) needs you to be logged in and is the weakest
  option — see [PRICE-TRACKING.md](PRICE-TRACKING.md) section 8 before using it.
  Per-bag watches are the real mechanism.

## If it still does not work

| What you see | What it means |
| --- | --- |
| No **Playwright** option in Fetch Method | The app has no driver URL → Step 0 |
| Fetch Method is Playwright but price is blank | No structured data on the page → *When no price appears* |
| Watch stuck on "Checking" | Chrome is wedged: `.\contrib\podman\logs.ps1 -Browser` |
| Preview shows a bare or unstyled page | Still on the basic fetcher — Step 3 was not saved |
| Alerts on every check, price unchanged | Threshold is 0 → set `2` in Step 6 |
| `403` / `503` / a CAPTCHA page | Interval too short → Step 8 |
