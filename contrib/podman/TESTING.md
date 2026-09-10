# Testing the Podman setup

A top-to-bottom procedure for verifying that changedetection.io builds and runs
under **rootless Podman**, starting from a machine with nothing installed.

Every step below is *do this → run this → expect this*. If the expected output
does not appear, stop there rather than continuing; the troubleshooting table at
the end is indexed by what you actually see.

Nothing here touches the Docker path. `Dockerfile`, `docker-compose.yml` and
`docker-entrypoint.sh` in the repository root are unmodified and keep working
exactly as they did.

> **No Podman on this machine?** Skip to [step 11](#11-no-local-podman-test-in-ci).
> CI runs this same build-and-verify sequence on every push, and you can trigger
> it by hand.

---

## 1. Prerequisites (Windows, one time)

Podman on Windows runs a Linux VM on top of WSL2, so WSL has to exist first.
Installing it is the **only step that needs administrator rights**.

```powershell
# elevated PowerShell
wsl --install --no-distribution
```

Then **reboot**. This is not optional — WSL is not usable until you do.

After the reboot, from a normal (non-elevated) PowerShell:

```powershell
wsl --status
winget install RedHat.Podman-Desktop
podman --version
```

| Expect | |
| --- | --- |
| `wsl --status` | version information, **not** "The Windows Subsystem for Linux is not installed" |
| `podman --version` | e.g. `podman version 5.2.0` |

On **Linux**, install Podman from your distribution instead (`dnf install podman`,
`apt install podman`) and skip to step 2 — there is no VM and no `podman machine`.

## 2. Start the Podman machine (Windows/macOS only)

```powershell
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
podman info
```

The 2 CPU / 2GB default is not enough once Chrome-based fetching is enabled,
hence the explicit sizes.

**`podman info` succeeding is a hard gate.** It prints the host and store
configuration. If it errors, nothing below this line will work — fix it first.

```powershell
podman machine list      # STATE should be "Currently running"
```

## 3. Get the code

```powershell
git clone https://github.com/dgtlmoon/changedetection.io.git
cd changedetection.io
```

All paths below are relative to this directory.

## 4. Build the image

```powershell
.\contrib\podman\build.ps1
```

This runs `podman build -t changedetection.io:dev -f Dockerfile .` and is the
main thing worth testing: the root `Dockerfile` uses BuildKit
`RUN --mount=type=cache` directives in three places, and this proves Buildah
handles them.

Verify:

```powershell
podman images changedetection.io
```

| Expect | |
| --- | --- |
| output | one row, `REPOSITORY` `changedetection.io`, `TAG` `dev` |

Two things that commonly look like failures and are not:

- **It is slow.** On Windows the repo is reached through a 9p mount at
  `/mnt/c/...`, and this image installs a large dependency tree. Genuinely
  stalled rather than slow? Build inside the VM instead:
  ```powershell
  podman machine ssh
  git clone https://github.com/dgtlmoon/changedetection.io.git ~/changedetection.io
  cd ~/changedetection.io && podman build -t changedetection.io:dev .
  ```
- **Cache-mount errors on an older Buildah.** Use `.\contrib\podman\build.ps1 -NoCache`.

## 5. Run it, and verify four ways

```powershell
.\contrib\podman\run.ps1
```

Then check each of these independently — they fail for different reasons, which
is the point of checking all four:

```powershell
podman ps                                   # a. the container is up
curl.exe -s -o NUL -w "%{http_code}" http://localhost:5000/    # b. the port answers
podman volume ls                            # c. the datastore volume exists
.\contrib\podman\logs.ps1                   # d. nothing is crash-looping
```

| Check | Expect |
| --- | --- |
| a | one row named `changedetection`, `STATUS` starting `Up` |
| b | `200` |
| c | a volume named `changedetection-data` |
| d | startup lines, no repeating traceback |

Then open <http://localhost:5000> — you should get the watch list UI.

If (a) shows `Up` but (b) does not return 200, give it another 20 seconds; first
start does some one-time setup. Still failing → step 10.

## 6. Functional smoke test

A listening port only proves Flask started. This proves the application works:

1. Open <http://localhost:5000>.
2. Paste a URL into **"Add a new change detection watch"** and submit.
3. Wait for the watch to leave the Queued / Checking state.
4. Click **Recheck** on it.

| Expect | |
| --- | --- |
| the watch | shows a **Last Checked** timestamp and a non-zero page size |
| `.\contrib\podman\logs.ps1` | fetch activity, no unhandled exception |

A watch stuck in Checking forever usually means outbound network from the
container is blocked — check with
`podman exec changedetection curl -sI https://example.com`.

## 7. Persistence test

This is the step that validates the whole named-volume design decision, and the
one most worth not skipping. Rootless Podman maps the container's root to your
unprivileged uid, which is exactly why `/datastore` is a **named volume** and not
a host bind mount.

```powershell
# write a marker into the datastore
podman exec changedetection sh -c "echo persisted-ok > /datastore/.smoketest"

# destroy the container entirely -- not stop, remove
podman rm -f changedetection

# recreate it
.\contrib\podman\run.ps1

# read the marker back
podman exec changedetection cat /datastore/.smoketest
```

| Expect | |
| --- | --- |
| final command | `persisted-ok` |

The watch you added in step 6 should also still be in the UI. If the marker is
gone, the volume is not being mounted — compare `podman inspect changedetection`
against the `-v changedetection-data:/datastore` argument in `run.ps1`.

Clean up the marker:

```powershell
podman exec changedetection rm /datastore/.smoketest
```

## 7b. With a real Chrome browser (optional)

Skip this if you only fetch plain HTML. Do it if you want JS-rendered pages,
Browser Steps or the Visual Selector — see [PRICE-TRACKING.md](PRICE-TRACKING.md).

```powershell
.\contrib\podman\run.ps1 -WithBrowser
```

Safe to run against an install that is already up. It removes the container and
recreates it inside a pod, but the `changedetection-data` volume — every watch,
every snapshot, all history — is reattached untouched. The same is true turning
the browser back off.

Then verify, in this order — each one rules out a different failure:

```powershell
# a. both containers are up, in one pod
podman ps --pod

# b. the app still serves
curl.exe -s -o NUL -w "%{http_code}" http://localhost:5000/

# c. the app can actually reach Chrome (this is the one that matters)
podman exec changedetection python -c "import socket; socket.create_connection(('localhost',3000),5); print('browser reachable')"

# d. Chrome is not crash-looping
.\contrib\podman\logs.ps1 -Browser
```

| Check | Expect |
| --- | --- |
| a | `changedetection` and `browser-sockpuppet-chrome`, both `Up`, same pod |
| b | `200` |
| c | `browser reachable` |
| d | startup lines, no repeated renderer crash |

**Then the check that actually proves it end to end:** open a watch → **Edit**.
A **Browser Steps** tab and the **Visual Selector** must now be present. They are
hidden whenever the app has no reachable browser, so seeing them means the wiring
is right — (c) alone only proves the port is open.

`test.ps1 -WithBrowser` automates a through c:

```powershell
.\contrib\podman\test.ps1 -WithBrowser
```

**The address differs by topology and the two are not interchangeable** — a pod
shares a network namespace so containers reach each other on `localhost`, while
separate containers on a network resolve each other by name:

| Path | `PLAYWRIGHT_DRIVER_URL` |
| --- | --- |
| `run.ps1 -WithBrowser`, `podman kube play` | `ws://localhost:3000` |
| `podman-compose`, Quadlet | `ws://browser-sockpuppet-chrome:3000` |

Getting this wrong looks exactly like a broken browser: the container is up and
healthy, and the app silently cannot talk to it.

## 8. The other two deployment paths

`run.ps1` is the quickest path. These are the two you would actually deploy
with, and each deserves its own up → verify → down cycle.

### 8a. podman-compose

`podman-compose` and `podman compose` are **different programs**:
`podman-compose` is a standalone Python implementation, while `podman compose`
delegates to whatever external compose binary it can find. These files are
written for and tested against `podman-compose`.

```powershell
pip install podman-compose

podman-compose -f contrib/podman/podman-compose.yml up -d
podman-compose -f contrib/podman/podman-compose.yml logs -f    # Ctrl-C stops following
curl.exe -s -o NUL -w "%{http_code}" http://localhost:5000/
podman-compose -f contrib/podman/podman-compose.yml down
```

| Expect | |
| --- | --- |
| `up -d` | container started, no error |
| `curl` | `200` |
| `down` | container removed; the **volume survives** |

To build through compose rather than pulling:

```powershell
podman-compose -f contrib/podman/podman-compose.yml build
```

With Chrome — the profile starts the browser, the env var tells the app where it
is, and **both are required**. Needs `podman-compose >= 1.0.4` for `--profile`:

```powershell
$env:PLAYWRIGHT_DRIVER_URL = "ws://browser-sockpuppet-chrome:3000"
podman-compose -f contrib/podman/podman-compose.yml --profile browser up -d
podman ps    # expect changedetection AND browser-sockpuppet-chrome
```

Here the containers are on a shared network rather than in a pod, so the address
is the **hostname**, not `localhost`.

### 8b. podman kube play

```powershell
podman kube play contrib/podman/changedetection-kube.yaml
podman pod ps
curl.exe -s -o NUL -w "%{http_code}" http://localhost:5000/
podman kube down contrib/podman/changedetection-kube.yaml
```

| Expect | |
| --- | --- |
| `podman pod ps` | a pod named `changedetection`, `STATUS` `Running` |
| `curl` | `200` |
| `kube down` | pod removed, PVC-backed volume kept |

For Chrome, uncomment the `browser-sockpuppet-chrome` container, the `dshm`
volume and the `PLAYWRIGHT_DRIVER_URL` env var in the manifest — all three, or
it will not work. Both containers share the pod, so the address is
`ws://localhost:3000`.

### 8c. Quadlet / systemd — Linux only

Not runnable on Windows or macOS; there is no user systemd in the Podman VM.

```bash
mkdir -p ~/.config/containers/systemd
cp contrib/podman/changedetection.container contrib/podman/changedetection.volume \
   contrib/podman/changedetection.network ~/.config/containers/systemd/

# optional: Chrome. Also uncomment PLAYWRIGHT_DRIVER_URL in
# changedetection.container, or the app will not know it exists.
cp contrib/podman/sockpuppetbrowser.container ~/.config/containers/systemd/

systemctl --user daemon-reload
systemctl --user start changedetection
systemctl --user status changedetection
journalctl --user -u changedetection -f

# keep it running after you log out
loginctl enable-linger "$USER"
```

| Expect | |
| --- | --- |
| `systemctl --user status changedetection` | `active (running)` |
| `curl -sf -o /dev/null -w "%{http_code}" http://localhost:5000/` | `200` |

The volume unit produces a volume named `changedetection-data`, as set by
`VolumeName=` in `changedetection.volume`.

## 9. Teardown

Increasing severity — stop at whichever line does what you meant.

```powershell
podman stop changedetection            # stop, keep everything
podman rm -f changedetection           # remove container, keep the data
podman volume rm changedetection-data  # remove the data: destroys every watch
podman rmi changedetection.io:dev      # remove the built image
podman system prune -a                 # reclaim dangling images and build cache
podman machine stop                    # shut the VM down (Windows/macOS)
```

Back up before doing anything destructive:

```powershell
podman volume export changedetection-data -o changedetection-backup.tar
podman volume import changedetection-data changedetection-backup.tar
```

## 10. Troubleshooting

| Symptom | Diagnose with | Cause and fix |
| --- | --- | --- |
| `podman info` fails; every command errors | `podman machine list` | VM not running → `podman machine start`. Absent → step 2. |
| `wsl --status` says WSL is not installed | — | Step 1, elevated, then reboot. |
| Build fails on `--mount=type=cache` | `podman version` | Older Buildah mishandles cache mounts → `.\build.ps1 -NoCache`. |
| Build hangs at a COPY or dependency install | `podman machine ssh`, then `top` | 9p slowness on `/mnt/c` → build inside the VM (step 4). |
| `Error: short-name ... did not resolve` | the failing image reference | Podman has no implicit Docker Hub. Fully qualify it: `ghcr.io/...` or `docker.io/...`. |
| Container starts then exits; logs show permission errors on `/datastore` | `podman inspect changedetection` | A host bind mount instead of the named volume. Rootless maps container root to your uid, so bind-mounted paths arrive unwritable. Use `changedetection-data:/datastore`. A deliberate bind mount on Fedora/RHEL also needs `:Z`. |
| `bind: permission denied` on start | the port in use | Rootless cannot bind below 1024. Keep 5000, or lower `net.ipv4.ip_unprivileged_port_start`. Put a reverse proxy in front rather than moving to 80/443. |
| Chrome fetching crashes: "Target closed", renderer failures | `podman logs browser-sockpuppet-chrome` | `/dev/shm` defaults to 64MB. Set `shm_size: 2gb` in compose, or `--shm-size=2g` on `podman run`. |
| Port 5000 answers, but every watch fails | `podman exec changedetection curl -sI https://example.com` | No outbound network from the container — check host firewall and VM networking. |
| `podman-compose: command not found` | `pip show podman-compose` | `pip install podman-compose`. Note `podman compose` is a different program. |

## 11. No local Podman? Test in CI

`.github/workflows/test-podman-build.yml` runs the same core sequence on a
GitHub runner — build with Podman, run the container, poll `:5000` until it
answers — and dumps container logs on failure. It triggers automatically on any
push touching `Dockerfile`, `requirements.txt`, `contrib/podman/**` or the
workflow itself, and can be started by hand:

```powershell
gh workflow run test-podman-build.yml --ref <branch>

gh run list --workflow test-podman-build.yml --limit 1
gh run watch <run-id>
gh run view <run-id> --log
```

This is the authoritative check when no local Podman is available. It does not
cover the Windows-specific parts (steps 1–2), `podman-compose`, `kube play`, or
the persistence test — run those locally when you can.

---

## Automated smoke test

`test.ps1` performs steps 4, 5, 7 and 9 in one command, and exits non-zero if any
of them fail.

It works on its own container (`cdio-smoketest`) and its own volume
(`cdio-smoketest-data`), never on `changedetection` / `changedetection-data`, so
running it cannot disturb or delete a real deployment's watches.

```powershell
# build from source, verify, tear down
.\contrib\podman\test.ps1

# skip the build and test an already-built or pulled image
.\contrib\podman\test.ps1 -Image ghcr.io/dgtlmoon/changedetection.io:latest

# leave it running afterwards so you can do steps 6 and 8 by hand
.\contrib\podman\test.ps1 -KeepRunning

# other options
.\contrib\podman\test.ps1 -Port 5001 -TimeoutSec 300 -SkipBuild -NoCache
```

It prints `PASS` / `FAIL` per stage and a summary line. On failure it dumps the
container logs before exiting, so the output is enough to find the matching row
in the troubleshooting table above.
