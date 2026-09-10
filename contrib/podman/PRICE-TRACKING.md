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

### How to know it actually worked

**First, that the container got the setting:**

```powershell
podman exec changedetection sh -c 'echo $PLAYWRIGHT_DRIVER_URL'
```

Prints `ws://localhost:3000` → good. Prints nothing → the app has no browser, and
nothing below will work.

**Then, in the UI.** Open any watch → **Edit** → **Request** tab and read the
**Fetch Method** options. (**Request**, not **General** — **General** carries the
URL, Processor and interval only.) The label tells you what the app actually connected to:

There are **three** radio options, always. The middle one is the one that
answers the question:

| Option | What it means |
| --- | --- |
| `Basic fast Plaintext/HTTP Client` | Raw HTTP, no browser. The default, and useless for a JS-rendered price |
| `Playwright Chromium/Javascript via 'ws://localhost:3000'` | Chrome is wired up ✅ — pick this one |
| `System settings default` | Follow **Settings → Fetching → Fetch Method** instead of deciding per watch |

If the middle option instead reads `WebDriver Chrome/Javascript`, with no URL
after it, the app never received `PLAYWRIGHT_DRIVER_URL` and fell back to
Selenium ❌.

`System settings default` is not a fourth fetcher — it is a deferral, stored as
`system` and resolved at fetch time. It is the better choice when you want every
watch to follow one global setting; pick the explicit Playwright option when you
want this watch pinned to Chrome no matter what the global default becomes.

The URL in that label matches your topology: `ws://localhost:3000` for
`run.ps1 -WithBrowser` and `podman kube play`, `ws://browser-sockpuppet-chrome:3000`
for compose and Quadlet.

### Now switch the watch to it — this part is not optional

**Select the Playwright option and Save.** Until you do, the watch still uses the
basic HTTP fetcher and behaves exactly as it did before, however well Chrome is
running.

Re-open **Edit** and a **Browser Steps** tab is now there. It was absent a moment
ago because that tab is driven by *the fetcher this watch uses*, not by whether a
browser exists — so it can only appear after you select one. Fetch Method first,
tab second.

To stop doing this per watch, set the default once under **Settings → Fetching →
Fetch Method**; new watches then inherit it.

> **The Visual Filter Selector tab proves nothing.** It is always present — it is
> driven by the *processor*, not the browser — and until the watch uses a browser
> fetcher it just says *"Sorry, this functionality only works with fetchers that
> support Javascript and screenshots"*. Judge by the Fetch Method label and the
> Browser Steps tab instead.

## 2. Watch a single product — the primary recipe

**Watch one product URL, not a category page.** A product page has exactly one
price in its structured data, which is precisely what the price mode wants.

1. Paste the product URL into **Add a new change detection watch**.
2. Open the watch → **Edit** → **Request** → set **Fetch Method** to the
   **Playwright Chromium/Javascript** option, and **Save**. Do this first: several
   things below only appear once the watch is on a browser fetcher.
3. Re-open **Edit** → set **Processor** to **Restock & Price detection**.
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

### Read the badge first — it says which failure you have

The price mode never reads the *visible* price. It parses the page's structured
product data: `<script type="application/ld+json">`, microdata `itemprop`
attributes, and OpenGraph `product:price:amount`. Whether the price is on screen
is irrelevant; whether it is in that metadata is the whole game.

So a restock watch that is not showing a price is in one of three states, and
the badge on the watch row tells you which:

| On the row | What actually happened | Where to go |
| --- | --- | --- |
| A price, e.g. `249 PEN` | Metadata found and parsed | nothing to fix |
| Red **`No information`** | The check completed, but neither price nor availability was in the metadata | the manual route below |
| An error banner instead of a badge | The check itself failed — timeout, `403`, CAPTCHA, browser unreachable | section 7, not this section |

`No information` is precise: it means the watch has never stored an
availability value. It is not "still loading" and not "the price is zero" — the
extractor ran and came back empty. No amount of waiting or rechecking changes
that, because the data is not on the page in a form the extractor reads.

A row stuck on **`Fetching…`** with `Not yet` under CHANGED is a different thing
again and is not a verdict at all: the check is *in progress*. Check the left
sidebar — **Queue 0 / Checking now: 1** means the fetch is running right now, so
the site is being slow or is refusing to answer. Some retailers accept a browser
from a residential IP and silently never respond to anything else, in which case
the fetch runs until it times out and the row never leaves `Fetching…`.

### The manual route

Some shops publish no structured data, or bury the price in a script. Extract it
manually instead:

1. Edit the watch → **Visual Filter Selector** tab → click the price on the rendered
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

If you do want it, scope a filter to a single product tile (Visual Filter Selector →
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
| Price column empty, no error | No structured data on the page → section 3 (Visual Filter Selector + `extracted_number`). |
| Red **`No information`** badge on the row | The extractor ran and found neither price nor availability in the page metadata → section 3. |
| Row stuck on `Fetching…`, sidebar shows `Checking now: 1` | Not stuck in a queue — the fetch is running and the site is not answering. See section 7's last row and the timeout test below. |
| Price empty **and** the page looks unrendered in Preview | Watch is still on the basic fetcher. Set **Fetch method** to Chrome; confirm Browser Steps is visible (section 1). |
| No **Browser Steps** tab at all | **Most likely: this watch is not on the Playwright fetcher.** That tab follows the watch's own Fetch Method, not whether a browser exists. Edit → Request → select the Playwright option → Save → re-open. |
| Fetch Method says `WebDriver Chrome/Javascript`, never Playwright | The app has no `PLAYWRIGHT_DRIVER_URL`, so it fell back to Selenium. Check with `podman exec changedetection sh -c 'echo $PLAYWRIGHT_DRIVER_URL'`. Pods use `ws://localhost:3000`, compose/Quadlet use `ws://browser-sockpuppet-chrome:3000` — they are not interchangeable. |
| **Visual Filter Selector** says "Sorry, this functionality only works with fetchers that support Javascript and screenshots" | Same cause: the watch is on the basic fetcher. That tab is always visible, so its presence never proved anything. |
| Watch stuck "Checking" forever | Browser unreachable or wedged: `.\contrib\podman\logs.ps1 -Browser`. |
| Chrome errors: "Target closed", renderer crashes | `/dev/shm` too small. `--shm-size=2g` (run.ps1 sets this), `shm_size: 2gb` in compose, the `dshm` emptyDir in the kube manifest. |
| Notifications on every check, price unchanged | Set **Threshold (%)** to 1–2. Whitespace or a rotating banner inside your filter also does this — tighten the selector. |
| `403` / `503` / CAPTCHA | The site is blocking automated access. Increase the interval first. Some sites will not be watchable at all. |
| No response at all — the fetch hangs until it times out | Harsher than a `403`: some WAFs simply never answer a client they distrust, so there is no status code to read. Test it from outside the app: `curl -sS -m 30 -o /dev/null -w '%{http_code} %{time_total}s
' -A 'Mozilla/5.0' '<the product URL>'`. A reset connection or 30s with no bytes means the site, not your setup. |
| Price detected but wrong (e.g. 10x) | Currency/decimal separator ambiguity, or you captured a "was" price. Check the Preview text and tighten the filter to the current price element. |

---

# Site-by-site walkthroughs

The sections above are the technique. For literal click-by-click instructions,
with every label quoted as the app shows it, use the per-site guides:

| Site | Guide |
| --- | --- |
| tous.com | [GUIDE-TOUS.md](GUIDE-TOUS.md) |
| amazon.com | [GUIDE-AMAZON.md](GUIDE-AMAZON.md) |

Both start with the same Step 0 — proving Chrome is actually connected — because
that is where this usually goes wrong.

---

## 8. Cart pages via session cookie

Both `https://www.tous.com/pe-es/cart` and `https://www.amazon.com/cart` require
you to be logged in. changedetection.io can send your session cookie so it sees
the same page you do — **no password is stored anywhere**.

1. Open the cart in your browser, logged in.
2. DevTools (**F12**) → **Network** → reload → click the document request for the
   cart page.
3. Under **Request Headers**, find `Cookie:` and copy the entire value.
4. In the watch → **Edit** → **Request headers**, add:

   | Key | Value |
   | --- | --- |
   | `Cookie` | *(the whole string you copied)* |
   | `User-Agent` | *(copy your browser's, from the same request)* |

5. Recheck and preview. Seeing your actual cart contents means it worked; being
   bounced to a login page means it did not.

**Read this before relying on it.** Three things make cart watching materially
worse than watching products, and none of them are fixable by configuration:

- **The cookie expires**, typically in days to weeks — sooner if you log out
  anywhere. When it does, the watch quietly starts seeing the logged-out page.
  It will look like the cart changed.
- **The cart changes when you change it.** Add an item, remove one, change a
  quantity — every one of those is a "change" and fires an alert that has
  nothing to do with price.
- **A cart is not a price feed.** It shows a total. A drop on one item and a rise
  on another can net out to no change at all.

So: use per-product watches as the real mechanism, and treat a cart watch as a
convenience for a shopping session you are actively running. If you do want a
cart watch, put a filter on the total element rather than watching the whole
page, and give it a long interval.

**Keep your cookie out of the repository.** It is a live credential for your
logged-in session — anyone holding it is you, on that site. It belongs in the
watch's settings in the app, nowhere else.
