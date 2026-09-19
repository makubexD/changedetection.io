# Using watch-from-url

Read this before your first run. It has real prompts, what actually comes back,
and what to do when the skill asks you something. `SKILL.md` is the procedure
the skill follows; `references/decisions.md` is why each rule in it exists.

> **A note on the examples below.** The output shapes here are grounded in facts
> this fork's own docs have already established by running against the real
> sites — the tucambista prices, the `MobileApplication` trap, the Amazon
> escalation ladder — all sourced from `contrib/podman/SITE-NOTES.md`. They are
> shown here as what a correct run *produces*, not as a transcript captured in
> this environment; running them for real depends on your own stack, network
> path and API key.

## Before you start

```powershell
.\contrib\maku.ps1 app start -WithBrowser      # needed if the value is JS-rendered
.\contrib\maku.ps1 app verify -WithBrowser     # must end PASSED
```

Applying a plan needs an API key from **Settings → API**, or set
`$env:MAKU_API_KEY` once per session. No key yet? Use `watch apply -AsZip
<path>` instead — see "Both ways to apply it" below.

If the stack is not running or missing the fork's runtime mount, every command
the skill runs refuses with the fix line rather than failing halfway:

```
FAIL  site probe
The container has no /maku-runtime/probe.py, so it is running without the fork's runtime mount.
  fix: .\contrib\maku.ps1 app start -WithBrowser   (restarts with the mount; your watches are untouched)
```

## The shortest thing that works

```
watch the dollar rate on https://tucambista.pe
```

The skill reads the instance, probes the page, and finds two rate buttons with
no way to tell which one you mean from "dollar rate" alone — Peru's TuCambista
quotes both a buy (Compra) and sell (Venta) rate in soles per dollar. It asks:

> The page has two rates: **Compra** (buying, you get soles) 3.348, and
> **Venta** (selling, you get dollars) 3.3715. Which one?

Answer, and it emits the plan, validates it, and — once you confirm applying —
shows what the first real check captured:

```
OK    checked   http://localhost:5000/edit/<uuid>
  captured: 3.348
```

## Saying more to get asked less

```
watch the Compra rate on https://tucambista.pe, check every 15 minutes on
weekdays during Lima market hours, alert me on any change
```

Nothing here is ambiguous, so nothing is asked. The plan comes back directly,
with the evidence for each field:

| Field | Value | Why |
|---|---|---|
| `include_filters` | `.tc-quote-rates button:nth-of-type(1) .tc-quote-rate-value span:first-child` | verified against the live page; matched exactly `3.348` |
| `processor` | `text_json_diff` | the page's only ld+json price sits in a `MobileApplication` offer, not this rate — see the tucambista example below |
| `fetch_backend` | *(unset — inherits)* | the value arrived over plain HTTP; no browser needed |
| `time_between_check_use_default` | `false`, `minutes: 15` | asked for explicitly |
| `time_schedule_limit` | Mon–Fri, 09:00, 7 hours, `America/Lima` | "weekdays during market hours" |

## Worked examples

### A product price on a real shop

> watch the price on https://tous.com/pe-es/.../p/123456789

Probe finds a price in the page's structured data, and the enclosing type is
`Product` — the offer is genuinely about the item on the page. No filter is
proposed; `restock_diff` reads the metadata directly, and a filter there would
be silently ignored. If the page needs Chrome to render the price at all
(`SITE-NOTES.md` documents this for tous.com), the skill retries with
`-WithBrowser` before concluding the value isn't there, and reports that it
had to.

### tucambista.pe — looks like a shop, isn't

The page publishes exactly one ld+json price, and Restock mode would happily
report it with a change arrow attached. The probe's evidence shows why that
number is wrong:

```
Restock & Price mode would find:
  price 3.3715 PEN
  -> it would report 3.3715 on ANY filter.

  published offers in 2 ld+json block(s):
    offer on MobileApplication      price 3.3715 PEN
    offer on SoftwareApplication    price 3.3715 PEN
    (one distinct price -- every watch on this URL reports it)
```

Both offers describe the TuCambista *app*, not the exchange rate. The skill
reads `MobileApplication`/`SoftwareApplication`, not `Product`, and switches to
`text_json_diff` with a verified selector instead of trusting the metadata.

### "alert me under S/ 3.40" on that same page

The matched text is `3.348` — three digits after the dot. `price_parser` (the
same library the app's own Conditions use) reads that as the integer `3348`,
not the decimal `3.348`, so a numeric Condition on it would never fire and
nothing in the UI would look wrong. The skill refuses to generate one:

> A Condition on this value can't work reliably — the app's own number parser
> reads `3.348` as 3348 (a thousands-separator misread), not the decimal on
> screen. Proposing a plain change-alert instead, with the direction named in
> the notification body, which uses different arithmetic that reads `3.348`
> correctly.

### "tell me about price changes, not delivery estimates"

This is a rule about *meaning*, not a fixed field — it maps to `llm_intent`
almost verbatim. The skill checks `app defaults -Json` first:

- **A model is configured** → proposes `llm_intent: "tell me about price
  changes, not delivery estimates"` and explains the tradeoff: this suppresses
  *after* the checksum advances, so a filtered-out change will not re-fire
  later, unlike a Condition.
- **No model is configured** → says so plainly, and asks whether to configure
  one (Settings → the LLM tab) or fall back to a Condition — which can only
  express this if the rule reduces to one of five fixed fields (see
  `decisions.md`); this one doesn't, so a Condition alone can't do it.

### An Amazon product

```
watch https://www.amazon.com/gp/product/B0XXXXXXXX/ref=abc?tag=xyz&th=1
```

The skill strips the URL to `https://www.amazon.com/dp/B0XXXXXXXX` before
doing anything else — the tracking parameters change under you and silently
break the watch later. It adds a real User-Agent as a request header (a
missing one is one of the cheapest signals Amazon blocks on), proposes a
12–24 hour interval up front rather than starting short and escalating, and
tries `restock_diff` with no filter first, since Amazon's structured data is
usually clean. It also says plainly: "some ASINs return a CAPTCHA from the
first check and no configuration reliably fixes that — if this one does,
raising the interval further and confirming the User-Agent are the only
levers; a price-history site may be the durable alternative."

### A page behind a login

```
watch my cart total at https://example.com/cart, use this cookie: <paste>
```

The skill accepts the cookie as a request header, but says plainly what does
not have a fix: the cookie will expire and the watch will quietly start
watching the logged-out page; a cart total nets a drop on one item against a
rise on another to nothing; and every add/remove you make yourself will fire
an alert. It asks whether you'd rather watch the product page directly.

### A JSON endpoint instead of the page

```
watch https://example.com/products/123 for the price, but it's built by
JavaScript
```

Plain HTTP finds nothing (`-WithBrowser` would work, but costs more and
forfeits the conditional-request saving). Before defaulting to the browser,
the skill asks whether the browser's Network tab shows a JSON/XHR request
carrying the number — if you paste that endpoint, it re-probes it directly
with a `json:` filter, which can be checked far more often than a rendered
page and costs the site less than a single browser check.

## What it will never do

- Emit a selector it has not tested against the live page in this run.
- Put a filter on a `restock_diff` watch — the processor never reads one.
- Generate a numeric Condition on a value shaped like a thousands-separator
  trap (`\d{1,3}\.\d{3}`).
- Reach for `fetch_backend: html_webdriver` when plain HTTP already returned
  the value.
- Apply a plan without running it through `Test-WatchPlan` first.

## What to do when it asks something you can't answer

Every question comes with a recommended default — take it, and the config
records that it was assumed rather than confirmed, so you can revisit it later
from the plan file.

## Editing before applying

The emitted `watch.json` is yours. Open it, change anything, and re-run:

```powershell
.\contrib\maku.ps1 watch apply -File plan.json
```

`Test-WatchPlan` runs automatically and catches the fields that fail silently
or at the API — a partial weekly schedule, a numeric duration, a filter on a
Restock watch — before anything is sent.

## Both ways to apply it

```powershell
# With an API key: creates the watch, forces a real check, proves it worked
.\contrib\maku.ps1 watch apply -File plan.json

# Without one: writes a ZIP for Settings -> Backup -> Restore.
# No verify step -- you find out it works when the scheduler runs it.
.\contrib\maku.ps1 watch apply -File plan.json -AsZip out.zip
```

## When it goes wrong

| You see | What it means | Where to look |
|---|---|---|
| `Test-WatchPlan` refuses before anything is sent | The plan has a field that would fail silently at the app, not just at the API | The refusal names every problem found — fix them, or ask the skill to regenerate |
| `POST /api/v1/watch failed: ...` | The API's own validation rejected something `Test-WatchPlan` doesn't check (e.g. an unknown proxy) | The server's message is printed verbatim |
| "The forced recheck had not landed after 60s" | The queue is busy, or the site is slow or blocking this client | `contrib/podman/SITE-NOTES.md` has the `curl.exe` test to tell the two apart |
| "the last check failed: ..." | The watch was created, but its first real check errored | Open the watch's **Preview** tab — it shows the filtered text, which is usually why |
| Everything succeeds but the captured text looks wrong | The probe's evidence was accurate for that moment, but the page has since changed, or your intended value was ambiguous | Re-run `site probe -Selector` and compare |

For anything not in this table, `contrib/podman/WATCHING.md` is the full
troubleshooting reference this skill is built on.
