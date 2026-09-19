# tucambista-compra.json — how it was generated, and what to check before applying

Generated on a machine with **no podman/docker**, following the `watch-from-url`
procedure by hand where the container-dependent steps couldn't run. The plan is
portable: hand it to a machine that has the stack running and apply it there.

## What was actually verified, live, on 2026-09-19

Run directly against `https://tucambista.pe`, using only the parts of
`contrib/runtime/probe.py` that don't need the full `changedetectionio` app
import (fetch, ld+json walk, selector ranking, `maku_conditional_fetch` — all
plain Python + `requests`/`bs4`, no container):

- **Fetch**: `200` in ~1.5s, plain HTTP, no browser needed.
- **The Restock trap**: the page's one published ld+json price (3.375 PEN that
  day) sits in `MobileApplication`/`SoftwareApplication` offers, never
  `Product` — confirms the documented tucambista.pe case still holds. Hence
  `text_json_diff`, no `processor` field set (its default), no
  `include_filters` that Restock mode would silently ignore.
- **The selector**: `--find '3.348'` against the live page returned exactly
  one real candidate (after fixing two bugs this run itself found — see the
  commit "Fix two bugs --find only hit by running it against the real page"):
  `.tc-quote-rates > button:nth-of-type(1) > span:nth-of-type(2) > span:nth-of-type(1)`,
  isolating `3.348` — the Compra (buy) rate.
- **The conditional-request verdict**: `no_validators` — the server sends
  neither `ETag` nor `Last-Modified`. Every check downloads the full ~160 KB
  page; there is no cheap-polling saving available here. This is why the
  interval below is 1 hour with a schedule window, not the 15–30 minutes
  `USAGE.md`'s illustrative example uses for a *hypothetical* site where
  conditional requests are supported — that assumption does not hold for the
  real tucambista.pe today.
- **The plan itself**: `Test-WatchPlan` (pure PowerShell, no podman) passes —
  no partial schedule, no numeric duration, no filter-on-Restock, nothing
  read-only.

## What could NOT be checked here, and should be before (or right after) applying

- **`app defaults`** never ran — it reads the live datastore inside the
  container. Before applying, run it on the target machine and check:
  - whether any tag's `url_match_pattern` matches `tucambista.pe` and would
    attach its own filters to this watch (they union, they don't override);
  - the real global `fetch_backend` and `time_between_check`, in case the
    1-hour interval below is tighter or looser than makes sense next to them;
  - whether `notification_urls` is empty here, meaning: it inherits the
    global target from `contrib/fork/SETUP.md` §6.
- **The selector was not verified through the app's own matcher**
  (`html_tools.include_filters`) — only through plain BeautifulSoup, which is
  the same engine but not literally the code path a watch runs. Re-run
  `site probe -Url https://tucambista.pe -Selector '<selector above>'` on the
  podman machine before trusting it fully.
- **Nothing was actually created or checked.** This file describes a plan,
  not a watch. `watch apply -File tucambista-compra.json` still needs to run
  against a live instance (or `-AsZip` for the restore path) to prove it.

## To apply it

```powershell
# On the machine with podman and the stack running:
.\contrib\maku.ps1 app defaults -Json                                   # check tags/globals first
.\contrib\maku.ps1 site probe -Url https://tucambista.pe -Selector '.tc-quote-rates > button:nth-of-type(1) > span:nth-of-type(2) > span:nth-of-type(1)'
.\contrib\maku.ps1 watch apply -File contrib\podman\plans\tucambista-compra.json
```

If price movement matters more than the fixed interval above, `WATCHING.md`'s
own guidance stands: a schedule window keeps a shorter interval affordable
without the conditional-request saving this site doesn't offer; shrinking the
window is a safer lever than shrinking the interval.
