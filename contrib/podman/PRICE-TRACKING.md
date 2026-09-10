# Tracking prices with changedetection.io

How to use this application to watch a product page and get told when the price
moves — especially when it **drops**.

changedetection.io has a purpose-built **Restock & Price detection** mode. It is
not a generic text diff with extra steps: it parses the structured product data
that shops publish (JSON-LD, OpenGraph, microdata), pulls out price and stock
status, and gives you numeric thresholds to trigger on. Use that mode and most of
the work is already done for you.

> Podman setup lives in [README.md](README.md); how to verify the stack works is
> in [TESTING.md](TESTING.md). This document is about using the app.

---

## 1. Turn the browser on

Plain HTTP fetching only sees the HTML the server sends. Many shops render price
and stock **client-side**, so without a real browser the price is simply absent.

Start the stack with Chrome:

```powershell
# simplest
.\contrib\podman\run.ps1 -WithBrowser

# or with compose
$env:PLAYWRIGHT_DRIVER_URL = "ws://browser-sockpuppet-chrome:3000"
podman-compose -f contrib/podman/podman-compose.yml --profile browser up -d
```

Restarting this way does not touch your existing watches — they live in the
`changedetection-data` volume, which is reattached to the new container.

**How to know it actually worked.** Open any watch → **Edit**. If the browser is
wired up you now see a **Browser Steps** tab and the **Visual Selector**. Those
two are hidden entirely when the app has no browser configured, so their presence
is the proof — not a log line.

Then set the watch's **Fetch method** to the Chrome/Playwright option instead of
the basic fetcher. This is per-watch; a watch created earlier keeps whatever it
had.

## 2. Watch a single product — the primary recipe

**Watch one product URL, not a category page.** A product page has exactly one
price in its structured data, which is precisely what the price mode wants.

1. Paste the product URL into **Add a new change detection watch**.
2. Open the watch → **Edit** → set **Processor** to **Restock & Price detection**.
3. Set **Fetch method** to Chrome (step 1).
4. Go to the **Restock & Price Detection** tab and set:

| Setting | What to put | Why |
| --- | --- | --- |
| **Follow price changes** | on | otherwise only stock changes count as a change |
| **Below price to trigger notification** | your target price | this is the "tell me when it gets cheap" trigger |
| **Above price to trigger notification** | leave empty | unless you also want rises |
| **Threshold (%) for price changes** | `1` or `2` | ignores cent-level jitter and currency-rounding noise |
| **Re-stock detection** | *In Stock only* | avoids alerts for an out-of-stock item whose price "changed" to nothing |

5. Save, then hit **Recheck** and confirm a price appears in the watch row.

**A price showing in the list is the real success signal.** If the column is
empty, the price was not extracted — go to section 3.

**Shortcut:** if you add a normal watch and the app spots product data on the
page, the watch row offers *"Switch to Restock & Price watch mode?"* with a Yes
button. Accepting does steps 2–3 for you.

## 3. When the price is not detected automatically

Some shops publish no structured data, or bury the price in a script. Extract it
manually instead:

1. Edit the watch → **Visual Selector** tab → click the price on the rendered
   page. That fills in a CSS/xPath filter scoped to that element. (Or write the
   selector yourself under **Filters & Triggers**.)
2. Preview the watch and confirm the filtered text is *just* the price, e.g.
   `S/ 249.00` — not the whole product block.
3. Now use a **Condition**: edit the watch → **Conditions**, and add

   > **Extracted number after 'Filters & Triggers'** — *less than* — `249`

   The app runs a price parser over the filtered text and exposes the result as
   a number, so `<` means "only notify me when it is cheaper than this".

Conditions and the Restock thresholds do the same job by different routes. Use
the Restock fields when the price is detected automatically, and Conditions with
`extracted_number` when you had to filter it out by hand.

## 4. Watching a category or listing page

Possible, and the weakest option — worth understanding before you reach for it.

A listing page changes when **anything** on it changes: a product sells out, the
grid reorders, a badge appears, a new item arrives. All of that is a "change",
and none of it is the price of the thing you care about. You will get alerts that
mean nothing and eventually stop reading them.

If you do want it, scope a filter to a single product tile (Visual Selector →
click that tile's price) so everything else on the page is ignored. At that point
you have rebuilt a single-product watch the hard way — which is the argument for
just watching the product URL.

Listing pages are genuinely useful for one thing: **noticing that new items
appeared** in a category. That is a different question from price, and worth its
own watch with price mode off.

## 5. Notifications that tell you which way it moved

The price processor exposes these tokens:

| Token | Meaning |
| --- | --- |
| `{{restock.price}}` | price at this check |
| `{{restock.previous_price}}` | price at the previous check |
| `{{restock.last_price}}` | last recorded price |
| `{{restock.in_stock}}` | stock status |

A body worth pasting in — it says the direction instead of making you compare two
numbers yourself:

```
{{watch_title}}

Now:    {{restock.price}}
Before: {{restock.previous_price}}
Stock:  {{restock.in_stock}}

{{watch_url}}
```

Set it per-watch under **Notifications**, or globally in **Settings →
Notifications** so every price watch inherits it.

## 6. Check intervals

For retail price tracking, **6–12 hours is right**. Prices change on merchandising
cycles, not by the minute.

Checking every few minutes does not get you the drop sooner in any meaningful
sense, and it does three bad things: it is the single most reliable way to get
your IP rate-limited or blocked, it multiplies Chrome memory usage across
watches, and it turns small rendering differences into a stream of false alerts.

If you are chasing a specific sale window, 1 hour is plenty. Set it per-watch —
the global default applies to everything otherwise.

## 7. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| Price column empty, no error | No structured data on the page → section 3 (Visual Selector + `extracted_number`). |
| Price empty **and** the page looks unrendered in Preview | Watch is still on the basic fetcher. Set **Fetch method** to Chrome; confirm Browser Steps is visible (section 1). |
| No **Browser Steps** tab at all | The app has no `PLAYWRIGHT_DRIVER_URL`, or it points somewhere unreachable. Pods use `ws://localhost:3000`, compose/Quadlet use `ws://browser-sockpuppet-chrome:3000` — they are not interchangeable. |
| Watch stuck "Checking" forever | Browser unreachable or wedged: `.\contrib\podman\logs.ps1 -Browser`. |
| Chrome errors: "Target closed", renderer crashes | `/dev/shm` too small. `--shm-size=2g` (run.ps1 sets this), `shm_size: 2gb` in compose, the `dshm` emptyDir in the kube manifest. |
| Notifications on every check, price unchanged | Set **Threshold (%)** to 1–2. Whitespace or a rotating banner inside your filter also does this — tighten the selector. |
| `403` / `503` / CAPTCHA | The site is blocking automated access. Increase the interval first. Some sites will not be watchable at all. |
| Price detected but wrong (e.g. 10x) | Currency/decimal separator ambiguity, or you captured a "was" price. Check the Preview text and tighten the filter to the current price element. |
