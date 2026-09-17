# Running changedetection.io with Podman

Installing, running, updating, and the rootless details that explain why the
files here look the way they do.

Everything targets **rootless** Podman, which is the default mode and the one
that matters if you cannot install or run Docker. The project's Docker support
is untouched and still works exactly as it did.

- Setting up a machine in order: [`../fork/SETUP.md`](../fork/SETUP.md)
- Proving it works, and running the test suite: [`VERIFY.md`](VERIFY.md)
- Using it to track prices: [`PRICE-TRACKING.md`](PRICE-TRACKING.md)

## The short version

```powershell
.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app start -WithBrowser   # http://localhost:5000
```

| Command | Use it when |
| --- | --- |
| `app build` | Building the image from this repo. `-NoCache` for an older Buildah |
| `app start` | Starting it — the everyday command. `-WithBrowser`, `-Image`, `-Port` |
| `app stop` | Removing the containers. The data volume is kept |
| `app logs` | Something is wrong. `-Browser` for Chrome's own logs, `-Tail` |
| `app update` | Pull new code and put it live in one step |
| `app verify` | Prove a deployment works, unattended |

`app start` and `app verify` both default to the locally built image and both
take `-Image` to use a published one instead. `app start` replaces the
container but never the volume, so switching `-WithBrowser` on or off on a live
install does not touch your watches.

## Windows: Podman Desktop + WSL2

Podman on Windows runs a Linux VM (`podman machine`) on top of **WSL2**, so WSL
has to exist first. Installing it needs administrator rights — the only elevated
step.

```powershell
# elevated PowerShell, once; reboot afterwards
wsl --install --no-distribution

winget install RedHat.Podman-Desktop

# 2 CPUs / 2GB is not enough once Chrome-based fetching is enabled
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start

podman info      # must succeed before anything below will work
```

Step-by-step with expected output at each stage:
[`VERIFY.md`](VERIFY.md#prerequisites-windows-one-time).

### Build speed

The repository lives on the Windows filesystem, which the podman machine reaches
through the 9p mount at `/mnt/c/...`. That path is slow, and this image installs
a large dependency tree. If a build feels stalled rather than merely slow, clone
**this fork** into the WSL filesystem and build there:

```powershell
podman machine ssh
git clone https://github.com/makubexD/changedetection.io.git ~/changedetection.io
cd ~/changedetection.io && git checkout maku-release && podman build -t changedetection.io:dev .
```

## With a real Chrome browser

JS-rendered pages, **Browser Steps** and the **Visual Selector** all need a
browser. `sockpuppetbrowser` provides one; it is optional and off by default.

```powershell
.\contrib\maku.ps1 app start -WithBrowser
.\contrib\maku.ps1 app logs -Browser
.\contrib\maku.ps1 app verify -WithBrowser
```

`-WithBrowser` also sets `DEFAULT_FETCH_BACKEND`, so on a *fresh* datastore new
watches already use Chrome. An existing install keeps its saved default until
you change **Settings → Fetching → Fetch Method**.

Confirming it actually worked is a UI-level check, and it is the step people
skip: [`VERIFY.md`](VERIFY.md#prove-chrome-is-wired-up).

### How the app addresses the browser depends on the topology

The two are **not interchangeable**. A pod shares a network namespace, so
containers reach each other on `localhost`; separate containers on a network
resolve each other by name.

| Path | `PLAYWRIGHT_DRIVER_URL` |
| --- | --- |
| `app start -WithBrowser`, `podman kube play` (**shared pod**) | `ws://localhost:3000` |
| `podman-compose`, Quadlet (**shared network**) | `ws://browser-sockpuppet-chrome:3000` |

Getting this wrong looks exactly like a broken browser: the container is up and
healthy, and the app silently cannot talk to it.

### The browser image is pinned by digest

Not `:latest`. That tag is rebuilt often and its Dockerfile installs whatever
Chrome Stable is current on build day (`ARG CHROME_VERSION=current`), so
`:latest` swaps Chrome underneath you with no change on your side. Upstream CI
broke exactly this way.

The digest appears in several files that cannot read each other. Do not edit
them by hand:

```powershell
.\contrib\maku.ps1 images show                        # what is pinned, and whether all files agree
.\contrib\maku.ps1 images pin browser sha256:<new>    # rewrite every one of them
.\contrib\maku.ps1 images verify                      # fail if they have drifted
```

To find a newer digest deliberately:

```bash
podman pull docker.io/dgtlmoon/sockpuppetbrowser:latest
podman image inspect docker.io/dgtlmoon/sockpuppetbrowser:latest --format '{{.Digest}}'
```

Then re-run `app verify -WithBrowser` before trusting it.

## Updating to the latest code

One command does the whole thing — pull, rebuild if and only if the pull touched
the image, restart:

```powershell
.\contrib\maku.ps1 app update -WithBrowser
```

It fast-forwards the branch you already have checked out. It never merges, never
switches branch and never pushes, so it is safe on a machine that only deploys.
It refuses on a dirty tree and on a diverged clone rather than guessing. Pass
the same `-WithBrowser` / `-Image` / `-Port` you would pass `app start`; they are
handed straight through.

Bringing new **upstream** commits into the release branch is a different job — a
merge, with conflicts to resolve and a push — and does not belong on a
deployment machine. Do that where you develop with
[`fork sync`](../fork/FORK-MODEL.md#fork-sync), then run `app update` here.

### What "the image changed" means

The `Dockerfile` copies a fixed set of paths and nothing else, so **only a change
to one of them can change the image**:

| Rebuild when these change | Never reaches the image |
| --- | --- |
| `Dockerfile` | `contrib/` — the CLI, the compose file, these docs |
| `requirements.txt` | `docker-compose.yml` |
| `changedetectionio/` — the application itself | `.github/` workflows |
| `changedetection.py` | the repository's own `README.md` |
| `docs/api-spec.yaml` | anything else in the repo |
| `docker-entrypoint.sh` | |

`app update` applies this table for you and prints which files, if any, forced
the rebuild. **When in doubt, just rebuild** — with the layer cache warm, a
rebuild that changes nothing re-uses every layer and finishes in seconds.

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

`AutoUpdate=registry` is set, so `podman auto-update` pulls and restarts on a new
`:stable` tag.

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
non-interactive shell. Every image here is written as `ghcr.io/...` or
`docker.io/...`.

**`--mount=type=cache`.** The root `Dockerfile` uses BuildKit cache mounts in
three places. Buildah supports them, so `podman build` works unmodified. On an
older Buildah that mishandles them, build with `app build -NoCache`.

**`podman-compose` vs `podman compose`.** These are different programs:
`podman-compose` is a standalone Python implementation, while `podman compose`
delegates to whatever external compose binary it can find. `podman-compose.yml`
is written for and tested against **`podman-compose`** (`pip install podman-compose`).

## Data and backups

Everything lives in the `changedetection-data` volume. `app stop` and
`app start` never touch it; only removing it explicitly does.

```bash
podman volume export changedetection-data -o changedetection-backup.tar
podman volume import changedetection-data changedetection-backup.tar
```
