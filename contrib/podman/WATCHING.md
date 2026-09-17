# Watching a value on a page

Recipes first, reference behind them. Getting the machine running is
[`../fork/SETUP.md`](../fork/SETUP.md); this is about using the app.

**Start every new page with one command.** It runs inside the container using the
app's own extractor, and answers in one shot which recipe you need:

```powershell
.\contrib\maku.ps1 site probe -Url <the page> -Selector '<css, optional>'
```

It prints four things, and the *empty* answer is usually the diagnosis: which
fetcher got the bytes, what Restock mode would find **regardless of any filter**,
what your selector actually matched, and whether this URL can be polled cheaply —
which is what decides how often you can afford to check it.

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

## Deciding when to check

**The app is a poller.** There is no push, no inbound webhook and no way for a
site to tell it something moved — so "check it when the page updates" is not a
setting, and hunting for one costs an evening. What exists, in the order worth
trying:

| Rung | What it buys | Where |
| --- | --- | --- |
| [Watch a cheaper URL](#1-a-cheaper-url) | the biggest win by far, and no cost to anyone | how you write the watch |
| [Conditional requests](#2-conditional-requests-this-fork-sends-them) | an unchanged page stops being a download | automatic here; `site probe` says whether the site plays along |
| [Interval and Scheduler](#3-the-interval-and-the-scheduler-most-people-miss) | check often *when it matters*, never otherwise | Edit → General |
| [Trigger from outside](#4-triggering-a-check-from-outside) | as close to event-driven as this gets | the API |

### 1. A cheaper URL

Not a setting — a decision about what to point at. Most product and rate pages
are rendered from a JSON endpoint the browser already calls. **F12 → Network →
Fetch/XHR → reload**, find the response carrying the number, and watch *that*
URL with the plain fetcher and a **JSONPath/JQ** filter.

Everything gets better at once: kilobytes instead of a megabyte, no Chrome and
no browser memory, and a history holding one field — so there is no rendering
noise to filter out afterwards, because none was ever fetched. A watch like that
can be checked ten times more often than a browser watch and still cost the site
less than one of today's checks.

### 2. Conditional requests: this fork sends them

Upstream never asks "has it changed?" before downloading: `If-None-Match` and
`If-Modified-Since` appear nowhere in `changedetectionio/content_fetchers/`, so
every check pulls the whole page whether or not it moved.

This fork patches that at runtime (`contrib/runtime/maku_conditional_fetch.py`,
loaded by the same mount as the price-decimals fix). It keeps the last `ETag` or
`Last-Modified`, offers it back on the next check, and when the server answers
**304 Not Modified** it hands the app the bytes it already had. Nothing else
changes: filters, hashing, history and notifications all run exactly as before,
on the same content, and reach the same verdict. The download is the only thing
that did not happen.

Whether a given site plays along is a per-site fact, so the probe **asks** rather
than assuming — many servers publish an `ETag` and then ignore it:

```powershell
.\contrib\maku.ps1 site probe -Url <the page>
```

```
Cheap polling (conditional requests):
  If-None-Match -- and a conditional request came back 304 Not Modified.
  -> SUPPORTED. ...
```

| The probe says | What it means for the interval |
| --- | --- |
| **SUPPORTED** | an unchanged check costs a reply with no body. 15–30 minutes is affordable |
| advertises a validator and ignores it | treat it as the row below |
| no `ETag` and no `Last-Modified` | every check is a full download. Keep the interval long, or go back to rung 1 |

Two limits, both structural. It applies to the **plain HTTP fetcher only** — a
browser fetch runs JavaScript and can never be answered from a cache. And the
memory is per container: a restart costs one full fetch per watch, once.

Set `MAKU_CONDITIONAL_FETCH=0` in the container's environment to turn it off; the
app is then exactly stock on this path.

### 3. The interval, and the Scheduler most people miss

The global default is **3 hours** (`changedetectionio/model/App.py`). Per watch:
**Edit → General**, untick *Use system defaults* and set your own.

Directly underneath it — and easy to scroll past — is a **weekly schedule**: for
each day, a start time, a duration, and a timezone. Enable it and the watch is
checked *only* inside those windows.

This is the setting that makes a short interval sane. A shop that reprices on
weekday mornings does not need to be asked anything at 03:00 on Sunday:

| Watch | Interval | Schedule |
| --- | --- | --- |
| Retail price | 6–12 hours | Mon–Sat, 08:00, 14 hours |
| A sale you are chasing | 1 hour | the days the sale runs |
| An exchange rate | 15–30 minutes | Mon–Fri, market hours, in `America/Lima` |

**6–12 hours for retail** is still the right default. Prices change on
merchandising cycles, not by the minute, and checking every few minutes does not
get you the drop sooner: it is the most reliable way to get rate-limited or
blocked, it multiplies Chrome memory across watches, and it turns small rendering
differences into a stream of false alerts.

### 4. Triggering a check from outside

The API is the only way in. It is also all you need, if something else already
knows the page changed:

```bash
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/watch/<uuid>?recheck=true"
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/tag/<uuid>?recheck=true"
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/watch?recheck_all=1"
```

The key is in **Settings → API**; the header is only enforced when you have
enabled it there. The UUID is in the watch's URL when you edit it.

Worth driving from a Windows scheduled task when the update time is *known* — a
rate published at a fixed hour, a drop that goes live at midnight — rather than
guessing at it with a short interval all day.

## Only real changes reach the history

A history full of reorders and rotating banners is not a history. Everything
below **prevents the snapshot from being written at all**, so the diff list stays
readable and the alerts stay believable. In order of power:

| Do this | Where | Kills |
| --- | --- | --- |
| Narrow the **CSS/JSONPath/JQ/XPath filter** to the element holding your value | Filters & Triggers | everything outside it, before a single byte is compared |
| **Remove elements** (subtractive selectors) | Filters & Triggers | the carousel, the "customers also bought" strip, a cookie bar |
| Untick **Added lines** / **Removed lines**, keep *Replaced/changed* | Filters & Triggers | "a new row appeared" on a page where only one number matters |
| **Block change-detection while text matches** | Filters & Triggers | a watch that fires on "Out of stock", a CAPTCHA page, a login wall |
| **Keyword triggers — trigger/wait for text** | Filters & Triggers | everything *except* the state you are waiting for |
| **Ignore text** + **Strip ignored lines** | Filters & Triggers | timestamps, view counts, "updated 3 minutes ago" |
| **Sort text alphabetically** | Filters & Triggers | a list whose order changes on every render |
| **Threshold (%) for price changes** | Restock & Price Detection | cent-level jitter, and currency rounding wobble |
| **Conditions** — *Extracted number* / *Page text* with ALL or ANY logic | Conditions | anything a fixed rule can express. Read [the `extracted_number` trap](#a-condition-on-extracted_number-never-fires) first |

**Start at the top.** A filter that matches one element makes most of the rows
below unnecessary, and every rule you do not need is a rule that cannot
misfire later.

### The AI option, and why it is not the default here

This version also has an **AI / LLM** tab: give a watch an *intent* in plain
words and the model judges each change against it, dropping the ones that do not
match — `changedetectionio/worker.py` sets `changed_detected = False`, so no
snapshot is stored and nothing is sent. It is genuinely the strongest filter
available, and the only one that handles "tell me about price changes, not about
the delivery estimate" without a selector.

It needs an API key and spends tokens **on every change**, with a monthly budget
in Settings that can either stop the LLM or skip checks entirely when exhausted.
Nothing in this guide assumes it, and the settings above cost nothing and behave
identically every run. Turn it on deliberately, or not at all.

## Seeing the history, and verifying it

Four views, no notification involved. Use them to prove a watch works *before*
wiring Telegram to it:

| To see | Where |
| --- | --- |
| When it last ran, and when it last *changed* | the watch list — two different columns, and the gap between them is the answer to "is it working or is nothing happening?" |
| What changed, between any two snapshots | the watch's **History**/diff page — pick the two timestamps yourself |
| What the app currently extracts | **Preview** on the watch. It shows the filtered text, which is what gets compared |
| The whole change history as a feed | the **RSS** link in the watch list — it already carries the access token. Per watch: `/rss/watch/<uuid>?token=…`, per group: `/rss/tag/<uuid>?token=…` |

The app publishes RSS even when the site it watches does not — which is the
cleanest way to read a real history, and to keep one after you stop looking at
the UI.

Unattended, the same facts come from the API:

```bash
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/watch/<uuid>/history"
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/watch/<uuid>/history/latest"
curl -H "x-api-key: <key>" "http://localhost:5000/api/v1/watch/<uuid>/difference/<from>/<to>"
```

A watch with **fewer than two snapshots has no history to show**, and that is the
usual reason a diff page looks empty on a watch that is working fine. Recheck it
once more and look again.

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
| I want it to check the moment the page changes | Nothing can: the app polls and no site pushes to it. The four things that *can* be done, best first — [deciding when to check](#deciding-when-to-check) |
| Every check downloads the whole page | Only if the server allows nothing better. `site probe` says which case you are in — [conditional requests](#2-conditional-requests-this-fork-sends-them) |
| The history is full of changes I do not care about | Filter before the snapshot is written, not after — [only real changes reach the history](#only-real-changes-reach-the-history) |
| The diff page is empty on a watch that works | Fewer than two snapshots. Recheck once more — [seeing the history](#seeing-the-history-and-verifying-it) |
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
