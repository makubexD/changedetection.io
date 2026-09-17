# Watching a value on a page

Recipes first, reference behind them. Getting the machine running is
[`../fork/SETUP.md`](../fork/SETUP.md); this is about using the app.

**Start every new page with one command.** It runs inside the container using the
app's own extractor, and answers in one shot which recipe you need:

```powershell
.\contrib\maku.ps1 site probe -Url <the page> -Selector '<css, optional>'
```

It prints three things, and the *empty* answer is usually the diagnosis: which
fetcher got the bytes, what Restock mode would find **regardless of any filter**,
and what your selector actually matched.

| It answers | Recipe |
| --- | --- |
| a price you want, under "Restock & Price mode would find" | **A** — the page does the work |
| a price you do **not** want, or none at all | **B** — filter it out yourself |

If the value already arrived over `plain HTTP (no browser)`, that watch does not
need Chrome. Turning it off saves memory and latency.

---

# Part 1 — Recipes

## A. A shop product

**One product URL, never a category page.** A product page has exactly one price
in its structured data, which is what this mode wants.

1. Paste the URL into **Add a new change detection watch**.
2. If the probe needed a browser: **Edit → Request → Fetch Method** →
   **Playwright Chromium/Javascript** → **Save**. Do this first — several things
   below only appear once the watch is on a browser fetcher.
3. **Edit → General → Processor** → **Restock & Price detection**.
4. On the **Restock & Price Detection** tab:

| Setting | Put | Why |
| --- | --- | --- |
| Follow price changes | on | otherwise only stock changes count |
| Below price to trigger notification | your target | the "tell me when it is cheap" trigger |
| Above price to trigger notification | empty | unless you also want rises |
| Threshold (%) for price changes | `1` or `2` | ignores cent-level jitter |
| Re-stock detection | *In Stock only* | no alerts for an out-of-stock item whose price "changed" to nothing |

5. **Save → Recheck.** A price in the watch row is the success signal.

Empty column instead? → [the badge tells you which failure](#which-failure-you-have).

## B. A value that is not a shop price

For pages that publish no usable price — or publish one that is not yours. A
currency rate, a fare, a figure in a table.

1. Add the watch.
2. **Edit → General → Processor** → **Webpage Text/HTML, JSON and PDF changes**.
3. **Edit → Filters & Triggers → CSS/JSONPath/JQ/XPath Filter** → a selector for
   the element holding *only* your number. Confirm before saving:
   ```powershell
   .\contrib\maku.ps1 site probe -Url <the page> -Selector '<css>'
   ```
4. **Save → Recheck → Preview.** The preview must contain the number and nothing
   else.

The watch now alerts on every change to that value — which for a rate is exactly
"tell me when it moved". Add a **Condition** only if you want a fixed threshold,
and read [the `extracted_number` trap](#a-condition-on-extracted_number-never-fires)
first: on some pages that field holds a different number than the one on screen.

**tucambista.pe is the worked example** — two rates, one page, no browser:
[SITE-NOTES.md](SITE-NOTES.md#tucambistape).

## C. Tell me which way it moved

The Telegram setup and the notification body are step 6 of
[`../fork/SETUP.md`](../fork/SETUP.md#6--get-notified) — written once, there, so
the from-scratch path does not need a detour.

What decides which tokens you use:

| Watch | Tokens |
| --- | --- |
| **Restock & Price** | `{{restock.price}}`, `{{restock.previous_price}}`, `{{restock.last_price}}`, `{{restock.in_stock}}` |
| **Text** | `{{diff_changed_to}}` / `{{diff_changed_from}}` — the new and old value of the thing that changed |

The text pair works best when one value changes per line, which a filter that
matches a single number guarantees. They are empty when there is no previous
snapshot, so guard any arithmetic on them.

Set the body per watch under **Notifications**, or once in **Settings →
Notifications** so every watch inherits it.

---

# Part 2 — Reference

## The price mode never reads your filter

This is the part that costs people an afternoon. The processor is handed the
whole page — `self.fetcher.content` in
`processors/restock_diff/processor.py` — and `include_filters` appears nowhere in
it. In Restock mode a CSS selector changes **nothing** about the number on the
row, and two watches on the same URL with different filters must report the same
price.

It also never reads the *visible* price. It parses
`<script type="application/ld+json">`, microdata `itemprop` attributes and
OpenGraph `product:price:amount`. Whether the price is on screen is irrelevant;
whether it is in that metadata is the whole game.

## Which failure you have

![Three watch rows: a price, the red No information badge, and a row still fetching](images/fig-watch-row.svg)

| On the row | What happened | Go to |
| --- | --- | --- |
| A price, e.g. `249 PEN` | metadata found and parsed | nothing to fix |
| Red **`No information`** | the check completed; neither price nor availability was in the metadata | [manual extraction](#manual-extraction) |
| An error banner | the *check* failed — timeout, `403`, CAPTCHA, browser unreachable | [troubleshooting](#troubleshooting) |
| **`Fetching…`** with `Not yet` | not a verdict — the check is running now | the site is slow or not answering |

`No information` is precise: the watch has never stored an availability value.
Not "still loading", not "the price is zero" — the extractor ran and came back
empty, and rechecking cannot change that.

## The failure that looks like success

The states above look like failures. This one does not, which is what makes it
expensive: the row shows a price, `In stock` and a change arrow, and reads as
working.

It happens when the page is **not a shop**. Restock mode will find a `price` in
any schema.org offer — including one describing something other than what you are
watching: a currency exchange publishing its sell rate inside a
`MobileApplication` offer, a booking page quoting a "from" fare.

The tells:

- the price never matches the page, and it is not a rounding or separator error;
- two watches on one URL with different filters report the **same** number;
- the number is one of several on the page and you cannot influence which.

`site probe -Url <page>` prints every offer the page publishes. If the one it
finds is not yours, no filter and no setting will fix it — **change the
processor, not the filter**: that is [Recipe B](#b-a-value-that-is-not-a-shop-price).

## Manual extraction

When a shop publishes no structured data:

1. **Visual Filter Selector** tab → click the price on the rendered page. That
   fills in a filter scoped to that element.
2. Preview and confirm the filtered text is *just* the price, e.g. `S/ 249.00`.
3. **Conditions** → *Extracted number after 'Filters & Triggers'* — *less than* —
   your value.

Use the Restock fields when the price is detected automatically, and Conditions
when you filtered it out by hand.

## A Condition on `extracted_number` never fires

...and the number on the row looks right. The value is written like `3.345`.
`price_parser` reads a dot before exactly **three** digits as a thousands
separator, so the field holds **3345** — and the app builds that field with the
same parser (`conditions/default_plugin.py`). Not a constant offset either: the
same watch extracts `3.35` on a day the value prints two decimals.

`site probe` flags it whenever it sees it. **Alert on the change itself**, not on
a threshold.

A Condition cannot express *direction* in any case — the rules engine is given
one check's data, with no previous value in scope. Direction comes from the
notification body, where the arithmetic is Jinja's `| float` and reads `3.344`
correctly.

## Why a text watch shows no price on the list

The price cell, the ▲/▼ arrow and the percentage all come from
`watch['restock']`, which only the Restock & Price processor writes. A Text watch
never has it, however well it is configured. That is the trade for being able to
track a value the page does not publish as structured data — the number reaches
you in the notification instead.

## Check intervals

**6–12 hours for retail.** Prices change on merchandising cycles, not by the
minute. Checking every few minutes does not get you the drop sooner and does
three bad things: it is the most reliable way to get rate-limited or blocked, it
multiplies Chrome memory across watches, and it turns small rendering differences
into a stream of false alerts. Chasing a specific sale window, 1 hour is plenty.

## Category and listing pages

The weakest option. A listing changes when *anything* on it changes — an item
sells out, the grid reorders, a badge appears — and none of that is the price you
care about. Scoping a filter to one product tile rebuilds a single-product watch
the hard way, which is the argument for watching the product URL instead.

They are genuinely useful for one thing: noticing that **new items appeared**.
That is a different question, and wants its own watch with price mode off.

## Cart pages, via session cookie

`tous.com/pe-es/cart` and `amazon.com/cart` need you logged in. The app can send
your session cookie — **no password is stored anywhere**.

1. Open the cart logged in → **F12 → Network** → reload → click the document
   request.
2. **Request Headers** → copy the whole `Cookie:` value, and the `User-Agent`.
3. Watch → **Edit → Request headers** → add both as key/value pairs.
4. Recheck and preview: your actual cart means it worked, a login page means it
   did not.

Three things make this materially worse than watching products, none fixable by
configuration: **the cookie expires** in days to weeks and the watch then quietly
sees the logged-out page; **the cart changes when you change it**, so every
add/remove fires an alert; and **a cart is a total, not a price feed** — a drop on
one item and a rise on another net out to nothing.

**Keep the cookie out of the repository.** It is a live credential for your
logged-in session; it belongs in the watch's settings and nowhere else.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Price column empty, no error | No structured data on the page → [Recipe B](#b-a-value-that-is-not-a-shop-price) |
| Red **`No information`** badge | The extractor ran and found no price or availability → [manual extraction](#manual-extraction) |
| My **text** watch shows no price on the list | [Expected](#why-a-text-watch-shows-no-price-on-the-list) — that column is Restock-only |
| I want a browser pop-up | There is none. The app has no web push; the in-app badge needs the tab open. Use Telegram — [SETUP step 6](../fork/SETUP.md#6--get-notified) |
| Row stuck on `Fetching…`, sidebar shows `Checking now: 1` | Not a queue — the fetch is running and the site is not answering. Use the `curl` test in [SITE-NOTES.md](SITE-NOTES.md) |
| Price empty **and** the page looks unrendered in Preview | Still on the basic fetcher. **Edit → Request → Fetch Method** → the Playwright option |
| No **Browser Steps** tab | Same cause: that tab follows the watch's own Fetch Method, not whether a browser exists |
| **Visual Filter Selector** says it needs a JS fetcher | Same cause again. That tab is always visible, so its presence never proved anything |
| Fetch Method offers no Playwright option | The app has no `PLAYWRIGHT_DRIVER_URL` — it fell back to Selenium. `.\contrib\maku.ps1 app verify -WithBrowser` |
| Only **two** Fetch Method options | You are in **Settings → Fetching**, not the watch. A watch adds "System settings default" on top |
| Chrome errors: "Target closed", renderer crashes | `/dev/shm` too small — `--shm-size=2g`, which `app start` sets |
| Notifications on every check, value unchanged | Set **Threshold (%)** to 1–2. Whitespace or a rotating banner inside your filter does this too — tighten the selector |
| Test notification arrives with example sentences | That watch has fewer than two snapshots. Recheck it and send again |
| `403` / `503` / CAPTCHA | The site is blocking automated access. Raise the interval first; some sites are not watchable |
| No answer at all until it times out | Harsher than a `403`: some WAFs never answer a client they distrust. Test from outside the app with `curl` — [SITE-NOTES.md](SITE-NOTES.md) |
| Price detected but wrong, in **text** mode | Separator ambiguity, or you captured a "was" price. Check the Preview and tighten the filter |
| Price detected but wrong, in **Restock & Price** mode | **Do not tighten the filter — it is not read.** [The failure that looks like success](#the-failure-that-looks-like-success) |
| A Condition on `extracted_number` never fires | [The thousands-separator trap](#a-condition-on-extracted_number-never-fires) |
| Two watches on one URL report the same price | Conclusive: Restock mode ignores per-watch filters. Change the processor |
| A deliberate **text** watch offers *"Switch to Restock & Price watch mode?"* | Click **No** — it only records the dismissal. **`Yes` reverts the processor AND calls `clear_watch()`, deleting every snapshot** |

---

## Per-site walkthroughs

| Site | |
| --- | --- |
| tucambista.pe | [SITE-NOTES.md](SITE-NOTES.md#tucambistape) — not a shop, needs no browser, and the case where price mode reports a number confidently and it is not yours |
| tous.com | [SITE-NOTES.md](SITE-NOTES.md#touscom) |
| amazon.com | [SITE-NOTES.md](SITE-NOTES.md#amazoncom) |
