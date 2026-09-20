# Why the skill works this way

The reasoning `SKILL.md` assumes. Every claim here traces to a specific file in
this codebase or to `contrib/podman/WATCHING.md` / `SITE-NOTES.md` — nothing
here is a general best-practice guess.

## Why not the import page

`changedetectionio/blueprint/imports/importer.py` has three tabs. The URL-list
tab parses only `URL<space>tags`. The Distill.io tab reads one include filter,
one subtractive selector, and throws the source's own `schedule` away
entirely. The XLSX tab tops out at url/title/one-xpath/interval/dynamic/folder.
None of them can carry `time_schedule_limit`, `conditions`, `trigger_text`,
`processor_config_*`, or `notification_*`. `POST /api/v1/watch` and the
backup-restore ZIP are the only two doors that carry a complete watch.

## Why omission, not completeness

`store/__init__.py`'s `add_watch()` builds a fresh `watch_base` (every model
default) and `.update()`s your keys on top. A field you do not send is not
"unset" — it is the watch-level default, and several of those defaults are
themselves sentinels meaning "inherit from the tag/global level":

| Field | Default | What sending a concrete value does |
|---|---|---|
| `fetch_backend` | `'system'` | opts out of the global fetch backend |
| `time_between_check_use_default` | `true` | opts out of the global interval |
| `notification_format` | `'System default'` | opts out of the global format |
| `notification_urls` | `[]` | **still inherits** — the cascade tests truthiness, so `[]` is indistinguishable from unset; use `notification_muted: true` to silence a watch instead |

Tag and global list-fields are **additive across levels**, not overriding —
`include_filters`, `subtractive_selectors`, `ignore_text`, `trigger_text` and
`text_should_not_be_present` all union watch + tag(s) + global
(`processors/text_json_diff/processor.py`). A tag whose `url_match_pattern`
matches the URL applies even if the watch was never assigned to it
(`store/__init__.py`'s `get_all_tags_for_watch`). This is why step 1 of the
procedure is reading `app defaults` before writing any filter.

## The failure modes, and why each rule exists

| Failure | Cause | The rule that prevents it |
|---|---|---|
| Watch imports clean, first check fails with `FilterNotFoundInResponse` | CSS selectors are never validated by any form (`forms.py`: `@todo CSS validator`) | Every selector is verified with `site probe -Selector` before being written down |
| A confident, wrong price with a change arrow | Restock mode reads the whole page's structured data and reports the first offer it finds — on tucambista.pe that offer describes the *app*, not the exchange rate, because it sits inside a `MobileApplication`/`SoftwareApplication` type instead of `Product` | Processor choice checks the enclosing ld+json `@type`, not just "a price exists" |
| Filter tightened over and over, price still wrong | `restock_diff`'s processor never reads `include_filters` at all (`processors/restock_diff/processor.py`) | Never emit a filter alongside `restock_diff` — `Test-WatchPlan` refuses this combination |
| A numeric Condition that never fires, nothing looks wrong | `price_parser` (used both by `conditions/default_plugin.py` and the probe's `extracted_number`) reads a dot before exactly three digits as a thousands separator — `3.345` becomes `3345` | Refuse a numeric Condition on a value matching `\d{1,3}\.\d{3}`; offer a plain change-alert with direction in the notification body instead (Jinja's `\| float` reads `3.344` correctly) |
| A watch permanently unschedulable | `time_schedule_limit` needs all seven lowercase weekday keys (`time_handler.py` looks each one up by `arrow.format('dddd').lower()`) and a real IANA `timezone`; a missing key or bad zone fails silently or late | Never emit a partial week; `Test-WatchPlan` refuses a schedule with fewer than seven day keys |
| The API rejects a schedule with a cryptic type error | `duration.hours`/`duration.minutes` must be **strings** (`"24"`, not `24`) — the form field stores them that way | `Test-WatchPlan` checks the type, not just presence |
| The API returns 400 on a custom interval | Needs **both** `time_between_check_use_default: false` **and** at least one unit `> 0` | `Test-WatchPlan` checks both together |
| A condition blocks every future change forever | `conditions/__init__.py` evaluates a rule with `jsonLogic`; an unregistered `field` name resolves to a missing var, which is falsy, which blocks every check from then on | Only the five registered fields are allowed: `extracted_number`, `page_filtered_text`, `levenshtein_ratio`, `levenshtein_distance`, `word_count` |
| A watch that looks healthy but never alerts | `restore.py` rehydrates a ZIP's `watch.json` with **no validation at all** — a bad config imports silently | Prefer the API path, which validates URL safety, proxy, interval, schedule timezone and notification URLs before creating anything |
| `.pdf` URL configured with a browser fetcher, ignored | `model/Watch.py`'s `get_fetch_backend` forces `html_requests` for any PDF regardless of what is set | Never propose `fetch_backend: html_webdriver` for a `.pdf` URL |
| A category, cart or login page produces constant noise | A listing alerts on any change to anything on it; a cart total nets opposing price moves to nothing; a session cookie in headers expires silently | Confirm the URL is a single product/value page before proceeding, per `WATCHING.md`'s per-site notes |
| Short interval gets the watch blocked | Frequent polling is the single biggest cause of `403`/CAPTCHA on sites like Amazon (`SITE-NOTES.md`) | Prefer a weekly `time_schedule_limit` window to a short bare interval |

## Condition vs. `llm_intent` — the asymmetry that matters

Both suppress a detected change, but not the same way:

- **A Condition** (`conditions/__init__.py`) is evaluated *before*
  `previous_md5` is advanced. A blocked change stays pending — the checksum
  still differs, so the very next check that satisfies the condition fires the
  (now possibly stale) change.
- **`llm_intent`** (`llm/evaluator.py`, called from `worker.py`) runs *after*
  `previous_md5` has already been updated. A suppressed change is consumed —
  it will not re-fire.

`llm_intent` is inert unless a model is configured (`app defaults -Json`
reports this under `llm.configured`); it is not a fallback to reach for when a
Condition's five fields cannot express the rule, unless the instance actually
has a model wired up.

## Notification tokens are processor-dependent

- `restock_diff` → `{{restock.price}}`, `{{restock.previous_price}}`,
  `{{restock.last_price}}`, `{{restock.in_stock}}`.
- `text_json_diff` → `{{diff_changed_to}}` / `{{diff_changed_from}}`.

Both are empty on a watch's first-ever notification (no previous snapshot yet)
— any arithmetic in a generated template must guard for that, exactly as the
canonical template in `contrib/fork/SETUP.md` §6 does.

## Host-only mode: what it is, and exactly where its authority ends

`contrib/runtime/probe.py`'s docstring states a rule this whole skill is built
on: an answer about the app's own extractor is never approximated, because an
approximation that disagrees with the real thing is worse than no answer.
`--host-only` (`contrib/commands/site/probe.ps1` auto-detects and switches to
it when podman is unreachable) holds that rule by *narrowing what it answers*,
never by *guessing* the parts it cannot.

**What stays identical in both modes**, because none of it needs the app
package, only `requests`/`bs4`/stdlib — proven live against tucambista.pe on a
machine with neither podman nor docker installed:
- the fetch itself (`fetch()`, plain HTTP only — no browser fetcher exists
  outside a container, `_fetch_with_browser` needs `PLAYWRIGHT_DRIVER_URL`)
- the ld+json offer walk (`collect_ldjson_offers`) — pure `re`/`json`, and this
  is the one that catches the `MobileApplication`-offer trap, so host-only
  mode can still make the Restock-vs-Text call correctly even though it
  cannot run Restock's own extractor
- selector candidate ranking (`find_candidates`) — pure BeautifulSoup
- the conditional-request verdict (`compute_conditional`,
  `contrib/runtime/maku_conditional_fetch.py`) — this module is fork-authored
  and stdlib-only, deliberately not part of `changedetectionio`, so it was
  never actually container-bound to begin with

**What is skipped outright, with no substitute** — approximating either would
be exactly the "second opinion that can drift from the first" the file's own
docstring forbids:
- `get_itemprop_availability` (the Restock & Price verdict) — reads
  ld+json/microdata/OpenGraph by rules only that function knows
- anything the live instance's datastore alone can answer — tags, their
  `url_match_pattern`, global `fetch_backend`/`time_between_check`/filter
  lists (`contrib/runtime/instance.py`, `app defaults`)
- actually creating or checking a watch (`POST /api/v1/watch`, the forced
  recheck) — there is no instance to create it on

**What is narrowed, not skipped** — real, but a lower-fidelity substitute,
always labelled `host_only: true` in its own output:
- `--selector` verification (`host_only_css_match`) uses plain
  `BeautifulSoup.select`, the SAME engine `find_candidates` already uses, not
  a second implementation — but only for CSS. `xpath:`/`xpath1:`/`json:`/
  `jq:`/`jqraw:` selectors need `elementpath`/`jsonpath_ng`/`jq`, the same
  dependency wall that makes importing `changedetectionio` itself impractical
  on a bare host, so those are refused rather than approximated
  (`is_app_only_selector`)

**The rule this enables**: a plan built with any host-only evidence is
provisional, not wrong — every fact in it was checked against the real, live
page, just not through every one of the app's own code paths. The
`<plan>.NOTES.md` file is what turns "provisional" into "actionable": it names
exactly which facts need re-confirming, and with which command, on a machine
that has the container.
