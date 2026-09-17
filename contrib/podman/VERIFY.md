# Verifying: the deployment, and the project's own tests

Two different questions, which is why they used to be two documents that mostly
said "not to be confused with the other one":

| Question | Answer |
| --- | --- |
| Is **this deployment** wired up and keeping its data? | `app verify` — [below](#1-verify-a-deployment) |
| Does **the code** still work? | `tests run` — [below](#2-run-the-projects-own-tests) |

Neither proves a given shop is watchable from here. Only a real watch does, and
that is [`PRICE-TRACKING.md`](PRICE-TRACKING.md).

---

## Prerequisites (Windows, one time)

Podman on Windows runs a Linux VM on top of WSL2, so WSL has to exist first.
Installing it is the **only step that needs administrator rights**.

```powershell
# elevated PowerShell
wsl --install --no-distribution
```

Then **reboot**. This is not optional — WSL is not usable until you do. After
the reboot, from a normal PowerShell:

```powershell
wsl --status                              # version info, not "not installed"
winget install RedHat.Podman-Desktop
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
podman info                               # a hard gate: nothing below works until this does
```

The 2 CPU / 2GB default is not enough once Chrome-based fetching is enabled,
and changing it later means recreating the machine.

On **Linux**, install Podman from your distribution (`dnf install podman`,
`apt install podman`) — there is no VM and no `podman machine`.

---

## 1. Verify a deployment

```powershell
.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app verify -WithBrowser
```

`app verify` does not build — verifying and building are separate jobs, so a
stale image cannot quietly pass as a fresh one. It works on its own container,
pod and volume (`cdio-smoketest*`), so running it can never disturb or delete a
real deployment's watches.

It asserts, in order:

| Stage | What it proves |
| --- | --- |
| preflight | podman is running, the image exists, and the port is free |
| run | the containers start |
| http | the app answers on the port — Flask started *and* finished its one-time setup |
| runtime | the fork's `contrib/runtime` patches reached the container and behave — nothing in the UI shows this, so it is asserted here or not at all. It reports **twice**: that the module loads and keeps 4 dp, then whether the hook is confirmed against the live `flask_app`. Only the second proves the patch reached the *running application*; a `WARN` there leaves that one thing unproven and fails nothing |
| browser | the app can open a socket to Chrome, **was told where it is**, and defaults new watches to it |
| persistence | the datastore survives the container being destroyed and recreated |

The browser stage is the one worth having. A listening port and a running Chrome
container can both be healthy while the app has silently fallen back to Selenium
— which is what happened twice in real use, looking fine both times.

**It publishes on 5099, not 5000.** This check runs on the machine the real
deployment runs on, and the ordinary sequence there is `app update` then
`app verify` — with a shared port that fails every time, and with `-WithBrowser`
it fails as `Error: starting some containers: internal libpod error` (exit 126),
because the pod's port is bound by its infra container and podman reports it from
there. Preflight now refuses up front and names the port instead.

Useful options: `-Image` to verify a published image instead, `-Port` to move it
again, `-KeepRunning` to leave it up for the manual checks below.

### Prove Chrome is wired up

This is the end-to-end confirmation, and the step people skip. Open a watch →
**Edit** → the **Request** tab (**not** General) → **Fetch Method**.

There are **three** radios, always:

| Option | What it means |
| --- | --- |
| `Basic fast Plaintext/HTTP Client` | Raw HTTP, no browser. The default, and useless for a JS-rendered price |
| `Playwright Chromium/Javascript via 'ws://localhost:3000'` | Chrome is wired up — pick this one |
| `System settings default` | Follow **Settings → Fetching → Fetch Method** instead of deciding per watch |

If the middle option instead reads `WebDriver Chrome/Javascript` with no URL
after it, the app never received `PLAYWRIGHT_DRIVER_URL` and fell back to
Selenium.

`System settings default` is not a fourth fetcher — it is a deferral, stored as
`system` and resolved at fetch time.

**Then select it and Save.** A watch keeps using plain HTTP until you do, and the
**Browser Steps** tab only appears afterwards, because that tab follows *the
fetcher this watch uses*. The **Visual Filter Selector** tab proves nothing — it
is always present and simply refuses to work until the watch uses a browser.

The URL in that label must match your topology; see the table in
[`DEPLOY.md`](DEPLOY.md#how-the-app-addresses-the-browser-depends-on-the-topology).

### The deployment paths `app verify` does not cover

`app start` is the quickest path. These are the ones you would actually deploy
with, and each deserves its own up → verify → down cycle.

**podman-compose**

```powershell
pip install podman-compose
podman-compose -f contrib/podman/podman-compose.yml up -d
curl.exe -s -o NUL -w "%{http_code}" http://localhost:5000/     # expect 200
podman-compose -f contrib/podman/podman-compose.yml down        # volume survives
```

With Chrome — the profile starts the browser and the env var tells the app where
it is, and **both are required**. Needs `podman-compose >= 1.0.4` for `--profile`:

```powershell
$env:PLAYWRIGHT_DRIVER_URL = "ws://browser-sockpuppet-chrome:3000"
podman-compose -f contrib/podman/podman-compose.yml --profile browser up -d
```

Here the containers share a network rather than a pod, so the address is the
**hostname**, not `localhost`.

**podman kube play**

```powershell
podman kube play contrib/podman/changedetection-kube.yaml
podman pod ps                                                   # expect Running
podman kube down contrib/podman/changedetection-kube.yaml
```

For Chrome, uncomment the `browser-sockpuppet-chrome` container, the `dshm`
volume and the `PLAYWRIGHT_DRIVER_URL` env var — all three, or it will not work.
Both containers share the pod, so the address is `ws://localhost:3000`.

**Quadlet / systemd** — Linux only; there is no user systemd in the Podman VM.
See [`DEPLOY.md`](DEPLOY.md#linux-quadlet-systemd). Expect
`systemctl --user status changedetection` to report `active (running)`.

### A functional smoke test, by hand

A listening port only proves Flask started. Add a watch, wait for it to leave
Queued/Checking, and click **Recheck**: it should show a **Last Checked**
timestamp and a non-zero page size. A watch stuck in Checking usually means no
outbound network from the container —
`podman exec changedetection curl -sI https://example.com`.

---

## 2. Run the project's own tests

```powershell
.\contrib\maku.ps1 tests run
```

That runs the price and restock tests through a real Chrome and prints a
verdict. First run builds the image; later runs reuse the layer cache.

### Why these tests are the ones worth running

They cover exactly what has broken in real use:

| Test file | What it proves |
| --- | --- |
| `tests/test_restock_itemprop.py` | Price extracted from `ld+json` — real-world shapes, min/max triggers, percent thresholds |
| `tests/restock/test_restock.py` | Price drop shows `▼ -18%`, rise shows `▲ +9.8%`, `last_price` tracked across checks — **through a real browser** |
| `tests/test_automatic_follow_ldjson_price.py` | The "switch to price mode?" suggestion |
| `tests/visualselector/test_fetch_data.py` | The Visual Filter Selector, browser-backed |
| `tests/fetchers/test_content.py` | Fetcher behaviour through Chrome |

**They never touch the public internet.** Fixture pages are served by a live
server inside the pod, so no retailer can block them, nothing goes flaky because
a shop changed its markup, and a result means the same thing every run.

That is also their limit: they tell you the *code* works. They cannot tell you
whether a particular shop will answer *your* connection.

### The suites

```powershell
.\contrib\maku.ps1 tests run                 # price   (the default)
.\contrib\maku.ps1 tests run -Suite unit     # fast, no browser at all
.\contrib\maku.ps1 tests run -Suite browser  # everything browser-backed
.\contrib\maku.ps1 tests run -Suite all      # the lot; slow
```

| Suite | Browser | Roughly |
| --- | --- | --- |
| `price` | yes | minutes |
| `unit` | no | under a minute |
| `browser` | yes | minutes |
| `all` | yes | long — leave it running |

Start with `unit` for a fast sanity check, `price` when you have touched anything
about fetching or price detection.

### Running one test

```powershell
.\contrib\maku.ps1 tests run -Path tests/test_restock_itemprop.py
.\contrib\maku.ps1 tests run -Path tests/test_restock_itemprop.py::test_itemprop_price_change
```

Iterating? `-NoBuild` skips the rebuild and reuses the last image — so a change
to application code will **not** be picked up. Drop it whenever you have edited
something under `changedetectionio/`.

### Reading the results

Every run writes a full log to `contrib/podman/test-logs/`, named by timestamp
and suite. The console prints the last line pytest itself wrote — that line is
the verdict, and nothing here reconstructs it. On failure it also lists each
failing test; open the log and search for that name to find the assertion, the
values compared, and the captured output. The command exits non-zero, so it can
gate anything you want it to.

Logs are untracked and accumulate — delete the folder whenever.

### A reasonable order after a change

```powershell
.\contrib\maku.ps1 tests run -Suite price      # does the code still work
.\contrib\maku.ps1 app update -WithBrowser     # put it live
.\contrib\maku.ps1 app verify -WithBrowser     # is the deployment wired up
```

---

## 3. No local Podman? Test in CI

`.github/workflows/test-podman-build.yml` runs the same core sequence on a GitHub
runner and is the authoritative check when no local Podman is available. What
each workflow does, and how to trigger it: [`../fork/CI.md`](../fork/CI.md).

```powershell
gh workflow run test-podman-build.yml --ref <branch>
gh run list --workflow test-podman-build.yml --limit 1
gh run watch <run-id>
```

It does not cover the Windows-specific prerequisites, `podman-compose`,
`kube play`, or the persistence test — run those locally when you can.

---

## Teardown

Increasing severity — stop at whichever line does what you meant.

```powershell
.\contrib\maku.ps1 app stop            # remove containers, keep the data
podman volume rm changedetection-data  # remove the data: destroys every watch
podman rmi changedetection.io:dev      # remove the built image
podman system prune -a                 # reclaim dangling images and build cache
podman machine stop                    # shut the VM down (Windows/macOS)
```

Back up before anything destructive — see
[`DEPLOY.md`](DEPLOY.md#data-and-backups).

---

## Troubleshooting

| Symptom | Diagnose with | Cause and fix |
| --- | --- | --- |
| `podman info` fails; every command errors | `podman machine list` | VM not running → `podman machine start`. Absent → prerequisites |
| `wsl --status` says WSL is not installed | — | Prerequisites, elevated, then reboot |
| Build fails on `--mount=type=cache` | `podman version` | Older Buildah → `app build -NoCache` |
| Build hangs at a COPY or dependency install | `podman machine ssh`, then `top` | 9p slowness on `/mnt/c` → build inside the VM, see [`DEPLOY.md`](DEPLOY.md#build-speed) |
| `Error: short-name … did not resolve` | the failing image reference | Podman has no implicit Docker Hub. Fully qualify it |
| `image 'changedetection.io:dev' does not exist` | `podman images` | `app verify` never builds → run `app build` first |
| Container starts then exits; permission errors on `/datastore` | `podman inspect changedetection` | A bind mount instead of the named volume → see [`DEPLOY.md`](DEPLOY.md#rootless-gotchas-and-why-the-files-look-the-way-they-do) |
| `address already in use` (exit 126) | `podman pod ps` | A pod from an earlier `-WithBrowser` run still owns the port. `app start` clears both topologies; from any other path: `podman pod rm -f changedetection-pod`, or `-Port` |
| `bind: permission denied` | the port in use | Rootless cannot bind below 1024. Keep 5000, or put a reverse proxy in front |
| Chrome: "Target closed", renderer crashes | `app logs -Browser` | `/dev/shm` too small — 64MB by default; `--shm-size=2g` / `shm_size: 2gb` |
| Port answers, but every watch fails | `podman exec changedetection curl -sI https://example.com` | No outbound network from the container |
| `browser container never became ready` | `podman logs cdio-suite-browser` | Chrome could not start; usually `/dev/shm` |
| Browser-backed tests fail, `unit` passes | — | Almost always Chrome, not your change |
| `-NoBuild was passed but … does not exist` | — | First run in this clone. Run once without it |
| Tests pass, the real watch still shows nothing | — | Expected and informative: the code is fine, so it is the site or the network → [`PRICE-TRACKING.md`](PRICE-TRACKING.md) |
| `podman-compose: command not found` | `pip show podman-compose` | `pip install podman-compose`. `podman compose` is a different program |
| Everything is slow | — | The repo is on the Windows filesystem, reached over 9p → [`DEPLOY.md`](DEPLOY.md#build-speed) |
