# Running this from GitHub

What GitHub can and cannot do with the Docker files, which workflow does what,
and how to trigger each one.

## First, the honest answer

**GitHub Actions cannot host the app.** Not a configuration problem — it is what
Actions is. A runner is a throwaway VM that:

- has **no inbound networking**. Nothing on the internet can reach it. There is
  no address to give anyone.
- is **destroyed when the job ends**, along with every container and volume.
- is capped at **6 hours** per job, and GitHub's terms are explicit that Actions
  is for building and testing the project, not for serving it.

So if "see it alive from GitHub" means a URL that stays up, the answer is no,
and nothing in this repository can change that. What GitHub *can* do is run the
whole stack inside a job and prove it works, publish an image you can then run
somewhere that is a real host, and — for a few minutes at a time — dial out to a
tunnel so you can click around a throwaway instance.

| What you want | Does GitHub do it? | How |
| --- | --- | --- |
| Prove the image builds | Yes | `Test Docker stack`, `Test Podman build` |
| Prove the app *runs*, with Chrome | Yes | `Test Docker stack` |
| Publish a runnable image | Yes | `Build and push container (maku)` → GHCR |
| A permanent public URL | **No** | Deploy the GHCR image to a host |
| A throwaway URL for a few minutes | Yes, with care | `Live preview` |
| Click around it yourself, GitHub-native | Yes | Codespaces (below) |

---

## `Test Docker stack` — the app running, verified

**Trigger:** automatically on any push touching `Dockerfile`,
`requirements.txt`, either compose file, or the workflow; on every pull request;
or by hand from **Actions → Test Docker stack → Run workflow**.

It brings up the app *and* real Chrome with `docker compose`, then asserts, in
order:

1. the app answers on `:5000`
2. `PLAYWRIGHT_DRIVER_URL` actually reached the container
3. the app can open a socket to the browser container
4. **the app offers the Playwright fetcher** on `/settings`
5. the app survives a container replacement with its named volume intact

**Check 4 is the reason this workflow exists.** Checks 1–3 can all pass while
the app has silently fallen back to Selenium — which is exactly what happened
twice in real use, looking like a healthy deployment both times. The only thing
that distinguishes them is the fetcher label, and until now the only thing
reading that label was a human following a table in
[`../podman/GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md). Now a job fails instead.

It reuses [`../podman/podman-compose.yml`](../podman/podman-compose.yml) rather
than carrying a CI-only copy: that file is plain Compose spec, so `docker
compose` reads it unchanged, and a second copy would be a second thing to keep
in step.

Reading a failure: each step is named after what it proves, so the red one names
the broken thing. The `Logs on failure` step dumps both containers.

## `Test Podman build` — the same, under Buildah

Narrower and deliberately so: it exercises the `Dockerfile`'s
`RUN --mount=type=cache` directives under Buildah, which is the main way a
Podman build can diverge from a Docker one. Single container, no Chrome.

This is the authoritative check for `contrib/podman/` when no local Podman is
available — which is the case on the machine most of this was written on.

## `Build and push container (maku)` — the image you can actually run

**Trigger:** every push to `maku-release`, any `maku-v*` tag, or by hand.

Publishes to `ghcr.io/makubexd/changedetection.io` (GHCR lowercases the
namespace). Tags: the branch name, a short SHA, and — only from `maku-release` —
the fixed alias **`:stable`**, which is what every deploy file pins. Never pin a
branch-derived tag: renaming the branch would silently break every deployment.

This is the bridge from CI to something live. Anywhere that runs a container can
run it:

```bash
docker run -d -p 5000:5000 -v cdio:/datastore \
  ghcr.io/makubexd/changedetection.io:stable
```

## `Live preview` — a URL, for minutes

**Trigger:** manual only — **Actions → Live preview → Run workflow**. Nothing
about it fires on a push, deliberately.

It starts the stack on the runner and dials out to a Cloudflare quick tunnel,
printing the URL to the run summary. Inputs: how many minutes to hold it open
(1–60) and whether to start Chrome.

**It requires a password and refuses to run without one.**

```bash
gh secret set PREVIEW_PASSWORD --body '<something long>'
```

That is not ceremony. changedetection.io fetches arbitrary URLs on command, so
an unauthenticated instance on a public URL is an open proxy — and on a public
repository the URL is in the run log for anyone to read. The workflow derives
`SALTED_PASS` from the secret on the runner using the same construction the
app's own password field uses (`changedetectionio/forms.py:105-114`), so the
plaintext never leaves the job.

What you get is genuinely disposable: empty datastore, thrown away at the end,
URL dead when the job stops. **It is a preview, never a deployment.** If you
find yourself re-running it to keep something alive, you want a host instead.

## Actually seeing it alive, GitHub-native

**Codespaces** is the part of GitHub that *can* run this for as long as you like,
with a forwarded port and a URL you can open:

```bash
gh codespace create -R makubexD/changedetection.io -b maku-release
gh codespace ports forward 5000:5000
```

then inside the codespace:

```bash
docker compose -f contrib/podman/podman-compose.yml --profile browser up -d
```

Port 5000 appears under the **Ports** tab; visibility defaults to private to you,
which is the right default for the reason above.

**GitHub Pages cannot do it** — Pages serves static files only, and this is a
Python application with a datastore.

---

## Which branch the workflows live on

All four live on **`maku-release` only**, alongside `contrib/fork/`. They name
this fork's image, its release branch, and its repository, so they are kept off
`master` (a pristine mirror) and off the `feat/*` branches, which stay
proposable upstream unchanged.

Upstream's own test workflows are **disabled at repository level** rather than
patched — workflow enable/disable is repo state, so it needs no commit, survives
every sync, and applies to the mirror branch too, which cannot carry a fix of
its own. See [`README.md`](README.md) for why this fork does not re-run
upstream's ~50-job matrix.

## When a run goes red

| Symptom | Cause |
| --- | --- |
| `App did not respond on :5000 within 120s` | The image built but the app died on boot. Read the `Logs on failure` step |
| `Expected 'ws://…' in the container, got ''` | The env var did not reach the app — a compose or workflow `env` problem, not an app one |
| `Settings offers no Playwright fetcher` | The app started without `PLAYWRIGHT_DRIVER_URL` and fell back to Selenium. The failure text prints the label it found instead |
| Chrome renderer crashes, "Target closed" | `/dev/shm` too small. `shm_size: 2gb` is set in the compose file |
| `Live preview` fails immediately | `PREVIEW_PASSWORD` is not set. It refuses rather than exposing an open instance |
| Tunnel reports no URL | Cloudflare quick tunnels are best-effort and occasionally unavailable. Re-run |
| A build breaks right after a browser image change | The browser is pinned by digest for this reason. See [`../podman/README.md`](../podman/README.md) |
