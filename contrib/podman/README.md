# Running changedetection.io with Podman

This directory **adds** Podman support. It does not change or replace the
project's Docker support — `Dockerfile`, `docker-compose.yml` and
`docker-entrypoint.sh` in the repository root are untouched and remain the
Docker path.

Everything here targets **rootless** Podman, which is the default mode and the
one that matters if you cannot install or run Docker.

## Start here

There are a lot of files in this directory because there are four different ways
to deploy. **You only ever need one of them.** Pick by what you are doing:

| I want to… | Go to |
| --- | --- |
| get it running on Windows, fastest | [Windows setup](#windows-podman-desktop--wsl2) → `build.ps1`, `run.ps1` |
| add Chrome so JS pages and prices work | [With a real Chrome browser](#with-a-real-chrome-browser) |
| prove the whole thing actually works | [TESTING.md](TESTING.md) |
| pull new code and put it live | [Updating](#updating-to-the-latest-code) → `update.ps1` |
| watch product prices (TOUS, Amazon) | [PRICE-TRACKING.md](PRICE-TRACKING.md) |
| deploy it properly on a Linux box | [Quadlet](#linux-quadlet-systemd) |

Shortest possible path from nothing to a running app with Chrome:

```powershell
.\contrib\podman\build.ps1              # build the image (once)
.\contrib\podman\run.ps1 -WithBrowser   # start app + Chrome
```

## What each file is for

**Documentation** — three files, no overlap:

| File | Read it when |
| --- | --- |
| `README.md` (this) | Setting up, or something behaves oddly and you want to know why |
| [`TESTING.md`](TESTING.md) | You want to verify a deployment step by step, with expected output |
| [`PRICE-TRACKING.md`](PRICE-TRACKING.md) | You have it running and want to *use* it to track prices |

**Windows scripts** — five, and they take the same arguments where it makes sense:

| Script | Use it when | Key options |
| --- | --- | --- |
| `build.ps1` | Building the image from this repo | `-Tag`, `-NoCache` |
| `run.ps1` | Starting it — the everyday command | `-WithBrowser`, `-Image`, `-Port` |
| `logs.ps1` | Something is wrong and you want to see why | `-Browser`, `-Tail` |
| `test.ps1` | Verifying end to end, unattended | `-WithBrowser`, `-Image`, `-KeepRunning` |
| `update.ps1` | Pulling new code and putting it live in one step | `-WithBrowser`, `-Image`, `-Port`, `-Tag` |

`run.ps1` and `test.ps1` both default to the locally built `changedetection.io:dev`
and both take `-Image` to use a published image instead. `run.ps1` replaces the
container but never the volume, so switching `-WithBrowser` on or off on a live
install does not touch your watches.

**Deployment files — pick exactly one:**

| File(s) | Use this path when |
| --- | --- |
| `podman-compose.yml` | You already think in compose files. Needs `podman-compose` installed |
| `changedetection.container` + `.volume` + `.network` | Linux server that should start at boot. Native Podman + systemd, no compose |
| `changedetection-kube.yaml` | You want one manifest that also works on real Kubernetes |
| *(none — just `run.ps1`)* | You are on Windows and want it running now |

`sockpuppetbrowser.container` is the optional Chrome add-on for the Quadlet path
only; the other paths carry their own browser definition.

## Windows: Podman Desktop + WSL2

Podman on Windows runs a Linux VM (`podman machine`) on top of **WSL2**, so WSL
has to exist first. Installing it needs administrator rights — this is the only
elevated step.

```powershell
# elevated PowerShell, once; reboot afterwards
wsl --install --no-distribution

winget install RedHat.Podman-Desktop

# 2 CPUs / 2GB is not enough once Chrome-based fetching is enabled
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start

podman info      # must succeed before anything below will work
```

### Then

```powershell
.\contrib\podman\build.ps1        # build the image from this repo
.\contrib\podman\run.ps1          # run it, http://localhost:5000
.\contrib\podman\logs.ps1         # follow the logs
.\contrib\podman\test.ps1         # smoke test: build, run, verify, tear down
```

Skipping the build? Point `run.ps1` at a published image instead — nothing else
changes:

```powershell
.\contrib\podman\run.ps1 -Image ghcr.io/dgtlmoon/changedetection.io:latest
```

### Updating to the latest code

One command does the whole thing — pull, rebuild if and only if the pull
touched the image, restart:

```powershell
.\contrib\podman\update.ps1 -WithBrowser
```

It fast-forwards the branch you already have checked out. It never merges,
never switches branch and never pushes, so it is safe on a machine that only
deploys. It refuses on a dirty tree and on a diverged clone rather than
guessing. Pass the same `-WithBrowser` / `-Image` / `-Port` you would pass
`run.ps1`; they are handed straight through.

Bringing new **upstream** commits into a release branch is a different job — a
merge, with conflicts to resolve and a push — and does not belong on a
deployment machine. Do that where you develop, then run `update.ps1` here.

The manual equivalent, if you would rather see each step:

```powershell
git pull
.\contrib\podman\build.ps1              # only if the IMAGE changed
.\contrib\podman\run.ps1 -WithBrowser   # always
```

`run.ps1` is safe to re-run at any time. It clears whatever the previous run
left behind — container, browser container and pod — then starts fresh against
the same `changedetection-data` volume, so your watches survive untouched.

#### What “the image changed” means

`build.ps1` bakes a fixed set of files into the image. The `Dockerfile` copies
these and nothing else, so **only a change to one of them can change the image**:

| Rebuild when these change | Never reaches the image |
| --- | --- |
| `Dockerfile` | `contrib/podman/` — all four scripts, the compose file, these docs |
| `requirements.txt` | `docker-compose.yml` |
| `changedetectionio/` — the application itself | `.github/` workflows |
| `changedetection.py` | the repository's own `README.md` |
| `docs/api-spec.yaml` | anything else in the repo |
| `docker-entrypoint.sh` | |

Everything changed here lately lives in `contrib/podman/`, which is not in the
image — so `run.ps1` on its own is enough after those pulls. `update.ps1` applies
this same table for you and prints which files, if any, forced the rebuild.

**Let git answer it for you.** Run this immediately after the pull, before
anything else touches the repo:

```powershell
git diff --name-only 'HEAD@{1}' HEAD -- Dockerfile docker-entrypoint.sh `
    requirements.txt changedetection.py changedetectionio/ docs/api-spec.yaml
```

Nothing printed → skip `build.ps1`. Any filenames → rebuild. `HEAD@{1}` is where
you were before the pull, which is why this has to run first — and the quotes
matter: PowerShell reads a bare `@{` as the start of a hashtable, and git then
fails with `Needed a single revision`.

**When in doubt, just rebuild.** With the layer cache warm, a rebuild that
changes nothing re-uses every layer and finishes in seconds. It is never wrong,
only occasionally slow.

On the compose path the equivalent is:

```powershell
podman-compose -f contrib/podman/podman-compose.yml --profile browser up -d --force-recreate
```

To check the whole setup rather than just start it, follow
[TESTING.md](TESTING.md) — it covers every deployment path, what each step
should print, and what to do when one of them does not.

### With a real Chrome browser

JS-rendered pages, **Browser Steps** and the **Visual Selector** all need a
browser. `sockpuppetbrowser` provides one; it is optional and off by default.

```powershell
.\contrib\podman\run.ps1 -WithBrowser    # app + Chrome in one pod
.\contrib\podman\logs.ps1 -Browser       # Chrome's own logs
.\contrib\podman\test.ps1 -WithBrowser   # verify the app can reach it
```

The proof it worked: open a watch → **Edit** → **Request** and read the **Fetch
Method** radios — the **Request** tab, not **General**. There are three of them:
`Basic fast Plaintext/HTTP Client`, the browser one, and `System settings default`.
The middle one must say `Playwright Chromium/Javascript via 'ws://localhost:3000'`.
If it says `WebDriver Chrome/Javascript` with no URL after it, the app never got
`PLAYWRIGHT_DRIVER_URL`.

Select that option and **Save** — a watch keeps using plain HTTP until you do,
and the **Browser Steps** tab only appears afterwards. `-WithBrowser` also sets
`DEFAULT_FETCH_BACKEND`, so on a *fresh* datastore new watches already use Chrome;
an existing install keeps its saved default until you change **Settings →
Fetching → Fetch Method**. Full walkthrough in
[PRICE-TRACKING.md](PRICE-TRACKING.md) section 1.

The browser image is **pinned by digest**, not `:latest`. That tag is rebuilt
often, and its Dockerfile installs whatever Chrome Stable is current on build day
(`ARG CHROME_VERSION=current`), so `:latest` swaps Chrome underneath you without
any change on your side. To move to a newer browser, do it deliberately:

```bash
podman pull docker.io/dgtlmoon/sockpuppetbrowser:latest
podman image inspect docker.io/dgtlmoon/sockpuppetbrowser:latest --format '{{.Digest}}'
```

then replace the digest in `podman-compose.yml`, `run.ps1`, `test.ps1`,
`sockpuppetbrowser.container` and `changedetection-kube.yaml`, and re-run
`test.ps1 -WithBrowser` before trusting it.

Watch out for one thing — how the app addresses the browser depends on the
topology, and the two are not interchangeable:

| Path | `PLAYWRIGHT_DRIVER_URL` |
| --- | --- |
| `run.ps1 -WithBrowser`, `kube play` (**shared pod**) | `ws://localhost:3000` |
| `podman-compose`, Quadlet (**shared network**) | `ws://browser-sockpuppet-chrome:3000` |

See [PRICE-TRACKING.md](PRICE-TRACKING.md) for what this unlocks.

Or pull the prebuilt image instead of building:

```powershell
podman pull ghcr.io/dgtlmoon/changedetection.io:latest
podman-compose -f contrib/podman/podman-compose.yml up -d
```

### Build speed on Windows

The repository lives on the Windows filesystem, which the podman machine reaches
through the 9p mount at `/mnt/c/...`. That path is slow, and this image installs
a large dependency tree. If a build feels stalled rather than slow, clone into
the WSL filesystem and build there:

```powershell
podman machine ssh
git clone https://github.com/dgtlmoon/changedetection.io.git ~/changedetection.io
cd ~/changedetection.io && podman build -t changedetection:dev .
```

## Linux: Quadlet (systemd)

The deployment path with no compose dependency at all.

```bash
mkdir -p ~/.config/containers/systemd
cp changedetection.container changedetection.volume changedetection.network \
   ~/.config/containers/systemd/

# optional: add Chrome, then uncomment PLAYWRIGHT_DRIVER_URL in
# changedetection.container so the app knows it is there
cp sockpuppetbrowser.container ~/.config/containers/systemd/

systemctl --user daemon-reload
systemctl --user start changedetection
journalctl --user -u changedetection -f

# keep it running after you log out
loginctl enable-linger "$USER"
```

`AutoUpdate=registry` is set, so `podman auto-update` pulls and restarts on a
new `:latest` tag.

## Rootless gotchas, and why the files look the way they do

**Use the named volume, not a bind mount.** Rootless Podman maps the container's
root to your unprivileged uid. A host bind mount at `/datastore` therefore
arrives owned by ids the container cannot write, and changedetection.io fails on
first write. `changedetection-data:/datastore` avoids this completely. If you do
bind-mount something (`proxies.json`, say), append `:Z` so SELinux relabels it —
required on Fedora/RHEL, harmless elsewhere.

**Chrome needs a bigger `/dev/shm`.** Podman defaults it to 64MB. The
`sockpuppetbrowser` service crashes with renderer / "Target closed" errors well
before that is genuinely exhausted, so `shm_size: 2gb` is set on it. The same
applies to a plain `podman run`: pass `--shm-size=2g`.

**Ports stay above 1024.** Rootless cannot bind privileged ports without
lowering `net.ipv4.ip_unprivileged_port_start`, so 5000 is kept as-is. Put a
reverse proxy in front rather than moving the container to 80/443.

**Image names are fully qualified.** Podman has no implicit Docker Hub, and an
unqualified name either prompts for a registry or fails outright in a
non-interactive shell. Every image here is written as
`ghcr.io/...` or `docker.io/...`.

**`--mount=type=cache`.** The root `Dockerfile` uses BuildKit cache mounts in
three places. Buildah supports them, so `podman build` works unmodified. On an
older Buildah that mishandles them, build with `.\build.ps1 -NoCache`.

**`podman-compose` vs `podman compose`.** These are different programs:
`podman-compose` is a standalone Python implementation, while `podman compose`
delegates to whatever external compose binary it can find. `podman-compose.yml`
is written for and tested against **`podman-compose`**.

```powershell
pip install podman-compose
```

## Data and backups

Everything lives in the `changedetection-data` volume.

```bash
podman volume export changedetection-data -o changedetection-backup.tar
podman volume import changedetection-data changedetection-backup.tar
```
