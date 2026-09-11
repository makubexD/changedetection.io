# Running the test suite

How to run the project's own tests on your machine, read the results, and use
them to check a change before it goes anywhere.

```powershell
.\contrib\podman\test-suite.ps1
```

That runs the price and restock tests through a real Chrome and prints a
verdict. First run builds the image; later runs reuse the layer cache.

> Not to be confused with [`test.ps1`](test.ps1), which smoke-tests a
> *deployment* — build, run, answers on `:5000`, keeps its data. This runs the
> *application's* tests.

## Why these tests are the ones worth running

They cover exactly what has broken in real use:

| Test file | What it proves |
| --- | --- |
| `tests/test_restock_itemprop.py` | Price is extracted from `ld+json` — 11 tests over real-world shapes (Ubiquiti, H&M, medimops), min/max triggers, percent thresholds |
| `tests/restock/test_restock.py` | Price drop shows `▼ -18%`, rise shows `▲ +9.8%`, `last_price` is tracked correctly across checks — **through a real browser** |
| `tests/test_automatic_follow_ldjson_price.py` | The "switch to price mode?" suggestion |
| `tests/visualselector/test_fetch_data.py` | The Visual Filter Selector, browser-backed |
| `tests/fetchers/test_content.py` | Fetcher behaviour through Chrome |

**They never touch the public internet.** Fixture pages are served by a live
server inside the pod, so no retailer can block them, nothing goes flaky because
a shop changed its markup, and a result means the same thing every run.

That is also their limit, and it is worth being clear about: they tell you the
*code* works. They cannot tell you whether a particular shop will answer *your*
connection — that is about where the request comes from, and only a real watch
on this machine answers it.

## The suites

```powershell
.\contrib\podman\test-suite.ps1                 # price   (the default)
.\contrib\podman\test-suite.ps1 -Suite unit     # fast, no browser at all
.\contrib\podman\test-suite.ps1 -Suite browser  # everything browser-backed
.\contrib\podman\test-suite.ps1 -Suite all      # the lot; slow
```

| Suite | Runs | Browser | Roughly |
| --- | --- | --- | --- |
| `price` | itemprop + ld+json + restock | yes | minutes |
| `unit` | `tests/unit/`, `tests/llm/` | no | under a minute |
| `browser` | restock, visual selector, fetchers | yes | minutes |
| `all` | `tests/` | yes | long — leave it running |

Start with `unit` when you want a fast sanity check, `price` when you have
touched anything about fetching or price detection.

## Running one test

The tightest feedback loop. Any pytest path or node id works:

```powershell
.\contrib\podman\test-suite.ps1 -Path tests/test_restock_itemprop.py
.\contrib\podman\test-suite.ps1 -Path tests/test_restock_itemprop.py::test_itemprop_price_change
```

Iterating on one test? Skip the rebuild after the first run:

```powershell
.\contrib\podman\test-suite.ps1 -Path tests/restock/test_restock.py -NoBuild
```

`-NoBuild` reuses the last image, so a change to application code will **not**
be picked up. Drop it whenever you have edited something under
`changedetectionio/`.

## Reading the results

Every run writes a full log to `contrib/podman/test-logs/`, named by timestamp
and suite. The console prints the last line pytest itself wrote — that line is
the verdict, and nothing here reconstructs it:

```
---------------------------------------------------------------
========== 11 passed, 2 warnings in 48.21s ==========
Full output: contrib\podman\test-logs\20260911-101500-price.log
---------------------------------------------------------------
PASSED
```

On failure it also lists each failing test:

```
Failures, in order, with the assertion that broke:
  FAILED tests/restock/test_restock.py::test_restock_price_change_direction
```

Then open the log and search for that test name. pytest prints the assertion,
the values it compared, and the captured output above it. The script exits
non-zero, so it can gate anything you want it to.

Logs are untracked and accumulate — delete the folder whenever. Nothing reads
them back.

## When it will not run

| Symptom | Cause |
| --- | --- |
| `podman build failed` | Usually disk or memory in the podman machine. `podman machine stop; podman machine set --memory 4096; podman machine start` |
| `browser container never became ready` | Chrome could not start. `podman logs cdio-suite-browser` before it is removed, or re-run and watch |
| Browser-backed tests fail, `unit` passes | Almost always Chrome, not your change. Check `/dev/shm` — the script passes `--shm-size=2g`, which is the usual cause when it is missing |
| `-NoBuild was passed but cdio-test:suite does not exist` | First run in this clone. Run once without `-NoBuild` |
| Tests pass here, the real watch still shows nothing | Expected, and informative: the code is fine, so the problem is the site or the network. See [`PRICE-TRACKING.md`](PRICE-TRACKING.md) |
| Everything is slow | The repo lives on the Windows filesystem, reached over 9p. See *Build speed on Windows* in [`README.md`](README.md) |

## What this does not replace

Running the suite proves the mechanism. It does not prove your deployment is
wired up — that is [`test.ps1`](test.ps1) and the Fetch Method check in
[`TESTING.md`](TESTING.md) — and it does not prove a given shop is watchable
from here, which only a real watch can tell you.

A reasonable order after a change:

```powershell
.\contrib\podman\test-suite.ps1 -Suite price   # does the code still work
.\contrib\podman\update.ps1 -WithBrowser       # put it live
.\contrib\podman\test.ps1 -WithBrowser         # is the deployment wired up
```
