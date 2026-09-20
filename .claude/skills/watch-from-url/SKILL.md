---
name: watch-from-url
description: Generate a changedetection.io watch from a URL and a sentence of context — probes the live page with the app's own extractor, picks selector/processor/interval from evidence rather than guessing, asks only what the evidence leaves ambiguous, and applies it via the API (or a restore ZIP) with a verified first check. Use when the user wants to "watch", "monitor", "track" or "alert me about" a page, price, rate or value, or asks to import/create a watch from a URL.
---

# watch-from-url

Turn a URL into a changedetection.io watch that works on the **first** check,
not eventually. Read `USAGE.md` in this skill's directory first if you have not
used it before — it has the prompts and the worked examples this file assumes.

The reasoning behind every rule here — why the import page can't be used, why
the config must be minimal, and the fork's own documented failure modes — is in
`references/decisions.md`. Read it before deviating from the procedure below.

## Before anything else

Refuse early, with the fix, rather than guessing your way through a broken
environment — except for one refusal you must NOT hit anymore:

- **`site probe` no longer requires podman.** It auto-detects: if the stack
  isn't reachable, it runs a degraded, host-only path automatically — real
  evidence from a real fetch, just narrower (see "Two modes" below and
  `references/decisions.md`). You do not choose this; the command does, and
  tells you when it has. Never route around it by hand-writing inline Python —
  that is exactly the maintenance trap this mode exists to close.
- **`app defaults` has no host-only equivalent and never will** — it reads the
  live instance's own datastore, which does not exist anywhere outside a
  running container. If it refuses, step 1 below is genuinely unavailable this
  run; say so in the plan's evidence notes rather than guessing at tags or
  global defaults.
- The stack must be running for full fidelity: `.\contrib\maku.ps1 app start
  -WithBrowser` if the page might need JavaScript. Host-only mode has no
  browser fetch at all — `-WithBrowser` is accepted and ignored, with a
  warning, not silently dropped.
- Applying via the API needs a key from Settings → API, or `$env:MAKU_API_KEY`.
  Without one, plan to apply via `-AsZip` instead. Neither is possible at all
  without a reachable instance — on a host-only run, the plan is the
  deliverable, and applying it is the next machine's job.

## Two modes, one procedure

| | Full-fidelity (podman reachable) | Host-only (auto, no podman) |
|---|---|---|
| Fetch, ld+json offer walk, `--find` ranking, conditional-request check | ✅ identical either way | ✅ identical either way |
| Restock & Price verdict | ✅ via the app's own extractor | ❌ skipped outright — no approximation exists |
| `--selector` verification | ✅ via the app's own matcher, any syntax | ⚠️ CSS only, via BeautifulSoup — real, but not the app's own code path |
| Instance tags / global defaults (`app defaults`) | ✅ | ❌ unavailable — no substitute |
| Create + verify the watch (`watch apply`) | ✅ | ❌ unavailable — write the plan, hand it off |

Every row marked ❌ or ⚠️ must be named explicitly in the plan's evidence
notes when it applies — never silently treated as equivalent to the
full-fidelity case. When any host-only evidence was used, write a
`<plan-name>.NOTES.md` alongside the plan (see step 8) — this is not optional
polish, it is the record of what still needs confirming on a machine that has
the container.

## The procedure

1. **Read the instance.** `.\contrib\maku.ps1 app defaults -Json`. This is the
   only way to see the global fetch backend, interval, filter lists, and —
   critically — every tag's `url_match_pattern`. A tag can attach to the new
   watch by matching its URL, not only by explicit assignment, and its filters
   then *union* with whatever you write, never override. Check this before
   proposing any filter. If it refuses (no podman), note in the plan's
   evidence that tags and global defaults could not be checked this run.

2. **Probe the baseline.** `.\contrib\maku.ps1 site probe -Url <url> -Json`.
   This alone answers: does the page load over plain HTTP, does Restock mode
   find a price *independently of any filter* (full-fidelity only — see
   "Two modes"), what is the enclosing `@type` of every published ld+json
   offer, and does the site support conditional requests. Every later
   decision cites this evidence — never assert a fact the probe could have
   checked, and never assert a fact host-only mode explicitly skipped.

3. **Find the value, if one was named.** `site probe -Url <url> -Find "<text>"
   -Json` returns ranked selector candidates, each with the text it isolates.
   Verify the one you intend to use with `-Selector` before writing it down —
   CSS selectors are never validated by the app itself, so "the probe matched
   it" is the only proof available before the watch's first real check.
   Nothing matched over plain HTTP → retry the same two calls with
   `-WithBrowser` (full-fidelity only; host-only mode has no browser fetch to
   retry with — say so and ask whether a cheaper JSON endpoint exists
   instead). Only set `fetch_backend: html_webdriver` if that is what made the
   difference; it forfeits the conditional-request saving, so it is never a
   default.

4. **Choose the processor from evidence, never from how the site looks.**
   `restock_diff` only when the probe's `restock` price is the one you want
   *and* the matching ld+json offer's enclosing type is `Product` — not
   `MobileApplication`, `SoftwareApplication`, or anything else. Otherwise
   `text_json_diff` with the selector verified in step 3. Never emit both a
   processor of `restock_diff` and an `include_filters` entry — the processor
   never reads it.

5. **Choose the interval from the measured conditional verdict**, not from a
   guess: `supported` → 15–30 minutes is affordable; `ignored` (server
   advertises a validator and answers 200 anyway) → treat as `no_validators`;
   `no_validators` or `unproven` → propose a long interval, or ask whether a
   cheaper JSON/XHR endpoint exists (F12 → Network → Fetch/XHR is the
   documented way to find one). Prefer a weekly `time_schedule_limit` window
   over shortening the interval — it is what keeps a frequent check sane.
   Translate timing words in the user's context into that structure; never
   emit a partial one (see the weekday-key constraint in `decisions.md`).

6. **Decide how a rule becomes a suppression mechanism**, only if the context
   asked for one:
   - A fixed numeric threshold on a value that looks like `\d{1,3}\.\d{3}` is
     refused — `price_parser` reads the dot as a thousands separator there, so
     the condition can never fire. Offer a plain change-alert with direction
     named in the notification body instead.
   - A natural-language rule ("tell me about restocks, not price typos") maps
     to `llm_intent` **only if** `app defaults` reports an LLM model
     configured. Say plainly if it isn't, and offer a Condition instead if one
     of its five fields (see `decisions.md`) can express the same rule.
   - Note the asymmetry if both are on the table: a Condition blocks *before*
     the checksum advances, so a suppressed change stays pending and can still
     fire later; an LLM suppression consumes the checksum permanently.

7. **Write the plan as the smallest config that says what you mean.** Start
   from nothing and add only fields that differ from the watch default —
   omission is how a field inherits from the tag/global level (see
   `decisions.md`). Do not write `fetch_backend: 'system'`,
   `time_between_check_use_default: true`, or `notification_format: 'System
   default'` — those are the inherit sentinels themselves. Leave
   `notification_urls` unset to inherit the global Telegram target from
   `contrib/fork/SETUP.md` §6 unless the context names a different one.

8. **Show the evidence, not just the config.** For every field set, name the
   probe fact that justified it. Say plainly what could not be determined
   (e.g. "could not confirm conditional-request support — the site returned a
   non-2xx to the test HEAD"). This is what lets the user correct one
   assumption without re-deriving the whole plan.

   **If any step ran host-only** (`site probe` degraded, or `app defaults`
   was unavailable), write `<plan-name>.NOTES.md` next to the plan file — see
   `contrib/podman/plans/tucambista-compra.NOTES.md` for the shape: what was
   verified and how, what could not be checked and why, and the exact
   commands to re-verify on a machine with the container before applying.
   This is the artifact that makes the plan safe to hand to another machine —
   never hand over the JSON alone when any evidence in it is host-only.

9. **Validate, then apply only on confirmation.**
   `.\contrib\maku.ps1 watch apply -File <plan>.json` runs `Test-WatchPlan`
   first — it catches the constraints in `decisions.md` before the API ever
   sees them — then POSTs, forces a recheck, and waits for it to land before
   reporting anything as fact. Use `-AsZip <path>` when no API key is
   configured; say plainly that path has no verify step. **If nothing here is
   reachable at all** (this run was host-only end to end), applying is not
   this machine's job: hand the plan + NOTES.md to a machine with the stack
   running, and give the exact `app defaults` / `site probe` / `watch apply`
   sequence to run there before trusting the result.

## What this skill will never do

- Emit a selector that was not tested against the live page in this run.
- Put `include_filters` on a `restock_diff` watch.
- Generate a numeric Condition on a value shaped like a thousands-separator trap.
- Default to `html_webdriver` when plain HTTP already returned the value.
- Apply a plan without running it through `Test-WatchPlan` first.
- Claim a Restock & Price verdict, or a selector match through the app's own
  matcher, when the evidence for it actually came from host-only mode.
- Hand over a plan containing any host-only evidence without its NOTES.md.
- Re-implement `probe.py`'s fetch/evidence logic inline instead of calling
  `site probe` (with or without a container) — if it cannot yet answer a
  question this skill needs, that is a gap in `probe.py`, not a reason to
  write a one-off substitute.
