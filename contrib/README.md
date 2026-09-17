# contrib — this fork's own tooling

Everything here is additive. The project's Docker support — `Dockerfile`,
`docker-compose.yml`, `docker-entrypoint.sh` in the repository root — is
untouched and remains the Docker path.

**This directory exists only on `maku-release`.** It names this fork's branches,
its upstream and its image, so it is kept off `master` (a pristine mirror) and
off the `feat/*` branches, which stay proposable upstream unchanged.

## Start here

| I want to… | Go to |
| --- | --- |
| **set up a machine from scratch** | **[`fork/SETUP.md`](fork/SETUP.md)** — the ordered path, with a check at every step |
| get it running, fastest | [`podman/DEPLOY.md`](podman/DEPLOY.md) |
| prove a deployment works, or run the test suite | [`podman/VERIFY.md`](podman/VERIFY.md) |
| watch product prices | [`podman/PRICE-TRACKING.md`](podman/PRICE-TRACKING.md) · [`podman/SITE-NOTES.md`](podman/SITE-NOTES.md) |
| understand who this clone commits and pushes as | `gid` — a separate tool, see [`fork/SETUP.md`](fork/SETUP.md) §2–4 |
| understand the branches | [`fork/FORK-MODEL.md`](fork/FORK-MODEL.md) |
| know what CI does | [`fork/CI.md`](fork/CI.md) |

Shortest path from nothing to a running app with Chrome:

```powershell
.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app start -WithBrowser      # http://localhost:5000
```

## One command, one grammar

```
maku <resource> <action> [options]
```

The resource says what you are operating on, the action says what you are doing
to it, and options only modify that operation. Run it with no arguments to see
everything, or with just a resource to see that resource's actions — so the
grammar is discoverable without opening this file.

```powershell
.\contrib\maku.ps1                 # every resource and action
.\contrib\maku.ps1 app             # just app's actions
```

| | | |
| --- | --- | --- |
| `app` | `build` `start` `stop` `logs` `update` `verify` | running the application |
| `tests` | `run` | the project's own pytest suite |
| `fork` | `sync` `status` | keeping up with upstream |
| `images` | `show` `pin` `verify` | the pinned container images |

Identity — who this clone commits and pushes as, and the pre-push guard that
refuses anything else — is **not here**. It was never specific to this fork, so
it lives in `gid`, installed once per machine and used in every repository on
it. [`fork/SETUP.md`](fork/SETUP.md) §2–4 has the three commands.

Full help for any command:

```powershell
Get-Help .\contrib\commands\app\start.ps1 -Full
```

## What is in here

| Path | What it is |
| --- | --- |
| `maku.ps1` | the only entry point; it discovers commands from the tree below |
| `commands/<resource>/<action>.ps1` | one file per command — adding one adds it to help automatically |
| `lib/*.psm1` | shared behaviour: podman, git, images, argument binding |
| `images.psd1` | every pinned image, in one place |
| `fork/` | documentation: setup, branches, CI |
| `podman/` | documentation and deployment files: compose, Quadlet, Kubernetes |

## Deployment files — pick exactly one

| File(s) | Use this path when |
| --- | --- |
| *(none — just `app start`)* | You are on Windows and want it running now |
| `podman/podman-compose.yml` | You already think in compose files |
| `podman/changedetection.{container,volume,network}` | A Linux server that should start at boot: native Podman + systemd |
| `podman/changedetection-kube.yaml` | You want one manifest that also works on real Kubernetes |

`sockpuppetbrowser.container` is the optional Chrome add-on for the Quadlet path
only; the other paths carry their own browser definition.
