# Site notes: tucambista, TOUS and Amazon

The technique lives in [`WATCHING.md`](WATCHING.md) — follow that first. This
page is only what differs per site: the URL to use, the header to set, and how
each one refuses you.

> **Whether a browser is needed is per site, not a rule.** The two shops render
> their prices client-side and need Chrome; tucambista does not, and turning it
> on there costs memory and latency for nothing. `site probe` says which you are
> looking at — if the value comes back over `plain HTTP (no browser)`, that watch
> does not need one.

## Where each setting lives

The edit screen is tabbed, and a setting you cannot find is almost always on the
other tab.

| Tab | Holds |
| --- | --- |
| **General** | Web Page URL, Group Tag, **Processor**, Title, **Time Between Check** |
| **Request** | **Fetch Method**, proxy, wait time, request headers |
| **Restock & Price Detection** | appears only after Processor is set to price mode |
| **Visual Filter Selector** | click an element on the rendered page to filter on it |

![The Edit screen tab strip, with General and Request called out](images/fig-edit-tabs.svg)

![The Request tab, with the Playwright option selected among the three Fetch Method radios](images/fig-fetch-method.svg)

![The General tab, with Re-stock and Price detection selected under Processor](images/fig-processor.svg)

> Drawn from a real session — same labels, same order, same wording. They are
> diagrams rather than screenshots, so they stay readable in both GitHub themes
> and can be diffed when the UI moves.

---

## tucambista.pe

**Not a shop.** It is a currency exchange, and it is here because it is the
worked example of the failure that does not look like one — read
[the failure that looks like success](WATCHING.md#the-failure-that-looks-like-success)
first.

**Do not use `Restock & Price` on this page.** The site publishes exactly one
`price` in its structured data, and it is the **Venta** rate — sitting inside a
`MobileApplication` / `SoftwareApplication` offer describing the TuCambista app,
not the exchange rate. Restock mode finds it, shows it, and attaches a change
arrow to it. Everything looks healthy.

No figure is quoted for it here, because the rate moves every day and a pinned
number in a note goes quietly false. The *identity* is the durable part, and one
`site probe` run re-checks it: the price under "Restock & Price mode would find"
and the number the **Venta** selector matches are the same one, and it is never
Compra.

Two consequences, both permanent:

- The **Compra** rate is in the page's HTML but in **no** structured-data block,
  so Restock mode can never report it, under any filter.
- Two watches here — one "Compra", one "Venta" — report the *same* number,
  because the processor reads the whole page and ignores each watch's filter.

**No browser needed.** Both rates are in the server-rendered HTML, so the
**Basic fast Plaintext/HTTP Client** fetcher is enough. Chrome costs memory and
latency here and buys nothing.

### The working setup

One watch per rate, both on `https://tucambista.pe`:

| | |
| --- | --- |
| **Processor** | Webpage Text/HTML, JSON and PDF changes |
| **Fetch Method** | Basic fast Plaintext/HTTP Client |

| Rate | CSS/JSONPath/JQ/XPath Filter |
| --- | --- |
| **Compra** | `.tc-quote-rates button:nth-of-type(1) .tc-quote-rate-value span:first-child` |
| **Venta** | `.tc-quote-rates button:nth-of-type(2) .tc-quote-rate-value` |

Compra needs the trailing `span:first-child`; its value element also carries a
`--` reference span, so without it the watch diffs `3.348--`. Venta's does not.

### Do not put a numeric Condition on Compra

Both watches are correct as **text** watches: they diff the rate and notify on
any change. What does **not** work here is a threshold.

| On screen | `extracted_number` |
| --- | --- |
| `3.345` | **3345** |
| `3.3725` | `3.3725` |

Those are one afternoon's rates; the next day's Compra of `3.344` extracted as
**3344**. The digits are not the point — the *shape* is.

The mechanism is in
[`WATCHING.md`](WATCHING.md#a-condition-on-extracted_number-never-fires); what
matters here is that it is not a constant offset, so you cannot correct for it —
on a day Compra prints `3.35` the same watch extracts `3.35`.

Not a bug to patch out either: `1.099` on a European shop page really does mean
one thousand and ninety-nine, and the page gives nothing to disambiguate it.
**Alert on the change, not on a threshold**, and read the direction out of the
notification — [SETUP step 6](../fork/SETUP.md#6--get-notified) does that
correctly, because Jinja's `| float` is not `price_parser`.

Confirm both before saving, rather than by rechecking and squinting at the row:

```powershell
.\contrib\maku.ps1 site probe -Url https://tucambista.pe `
  -Selector '.tc-quote-rates button:nth-of-type(1) .tc-quote-rate-value span:first-child'
```

### The app will offer to undo this, and the offer deletes your history

Once these are text watches, each row shows:

> **Switch to Restock & Price watch mode?**  `Yes`  `No`

It appears because the page genuinely does publish ld+json price data -- the
prompt is right about that and wrong about what it is for.

**Click `No`.** It records the dismissal and the prompt stops appearing. Nothing
else changes.

The dismissal is written straight to disk as the click is handled, not held in
memory for a later flush, so it survives `app update`, a rebuilt container and a
reboot. Nothing a recheck does touches it. **One thing brings the prompt back:**
`Clear history` on that watch, which resets the flag along with everything else
— the same call `Yes` makes. If the prompt reappears months from now, that is
what happened, and it still means nothing new about the page.

**`Yes` is not a display toggle.** It sets the processor back to `restock_diff`
-- the mode that cannot read Compra and reports Venta on both watches -- and it
calls `clear_watch()`, which **discards every snapshot the watch has collected**.
Two irreversible things behind the more inviting of the two buttons.

**Do not key a selector on `data-selected`.** Both rate buttons carry it and it
flips when the widget is clicked, so a filter built on it silently starts
matching the other rate.

**The markup is the fork's only hold on this page**, and it is a marketing site
that can be redesigned without warning. When a watch here goes quiet or starts
diffing the wrong thing, re-run `site probe` before assuming the app broke.

---

## tous.com

**Use the product URL, not the category.** Open the category, click into the
specific item, and copy that URL — it looks like
`https://www.tous.com/pe-es/.../p/XXXXXXXXX`. A `/c/486` listing changes when
any item on it sells out, when the grid reorders, when a badge appears; you
would get constant alerts and none about your price.

**Currency is Peruvian soles (`S/`).** If a price is detected but looks 100× or
1/100 off, the decimal separator was misread — tighten the filter to the exact
price element.

**Discounted items show a struck-through "was" price.** If your filter grabbed
that one you will track the wrong number. Check the preview text.

**How it refuses you: silence.** TOUS does not always send a `403`. The harsher
behaviour is to accept the connection and never answer, so the fetch runs until
it times out and the row simply sits on `Fetching…` forever. Confirm from
outside the app:

```powershell
curl.exe -sS -m 30 -o NUL -w "%{http_code} in %{time_total}s`n" `
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36" `
  "<the product URL>"
```

| What comes back | What it means |
| --- | --- |
| `200 in 0.8s` | The site is fine; the problem is inside the app → `app logs -Tail 80` |
| `000` after the full 30s, or `Connection was reset` | TOUS is refusing this client. No status code, no CAPTCHA — just silence |

This can depend on where the request comes from: a residential connection may be
served normally while a datacenter or VPN address is not, so the same watch can
behave differently on two machines.

If it is merely slow rather than refused, give the fetch more room:
**Edit → Request → Wait seconds before extracting text**, try `10`.

---

## amazon.com

**Read this first.** Amazon actively detects and blocks automated browsers. Some
listings work for months; others return `503`s or a CAPTCHA from the first check
and never work at all. That is not a mistake in your setup, and no setting
reliably defeats it.

**Strip the URL back to the ASIN form:**

```
https://www.amazon.com/dp/B0XXXXXXXX
```

Delete everything from `/ref=` onwards, and any `?tag=`, `?th=`, `?psc=`. The
`/dp/<ASIN>` form is stable; long titled URLs change under you and silently break
the watch later. The ASIN is also on the page under **Product details**.

**Set a real User-Agent — this matters more here than anywhere else.** A default
or missing UA is one of the cheapest signals to block on.

1. In your own browser: **F12** → **Network** → reload the product page → click
   the first document request → **Request Headers** → copy the `User-Agent`.
2. In the watch: **Edit** → **Request** → **Request headers**, add
   `User-Agent` with that value. **Save.**

**Use a long interval — 12 hours, or daily.** On Amazon this is not politeness,
it is the single biggest factor in whether the watch keeps working.

**Structured data is usually clean.** Amazon product pages normally carry
`ld+json`, so price mode often works with no filter at all. Try it before
reaching for the Visual Filter Selector. Watch out for the **"List price"**
struck-through figure and any *"$X.XX with Subscribe & Save"* line — it is easy
to capture the wrong one.

**How it refuses you:** `503`, a CAPTCHA page in the preview, a page that renders
with no price — or, like TOUS, a row that sits on `Fetching…` and never
finishes, because the harsher defences never answer at all. Confirm it the same
way, with the `curl.exe` command above.

In order of what actually helps:

1. **Raise the interval to 24 hours.** Do this first.
2. **Make sure the User-Agent is set** and matches a real browser.
3. **Wait.** Blocks are often temporary; hammering extends them.
4. **Accept that some ASINs will not be watchable.** No configuration fixes this.

A durable alternative for a stubborn product is to watch a price-history site's
page for that ASIN instead. It updates less often, but it will not block you.

---

## Cart pages

`https://www.tous.com/pe-es/cart` and `https://www.amazon.com/cart` both need you
to be logged in, so they need your session cookie —
[`WATCHING.md` §8](WATCHING.md#cart-pages-via-session-cookie).

Amazon's cart is among the most heavily defended pages on the site, and a
headless browser reaching it from a datacenter IP is exactly the pattern they
look for; it may simply never work.

**Per-product watches are the mechanism.** Treat a cart watch as a convenience
for a shopping session you are actively running, nothing more.

---

## If it still does not work

The general table is in
[`WATCHING.md`](WATCHING.md#troubleshooting) — one copy, so it cannot drift.
Only these are site-specific:

| What you see | What it means |
| --- | --- |
| Worked for weeks, then stopped | A block (raise the interval), or the URL was never the stable form |
| Row sits on **`Fetching…`** forever | The site is not answering — the `curl.exe` test for that site above |
| No **Request** tab at all | This watch's processor has no request settings — re-add the watch |
