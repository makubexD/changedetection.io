# Setting up a machine

From a machine that has never seen this fork, to one that runs the app and can
safely push to it.

Every step has a **check**. Do not move past a failing one — each step assumes
the last worked. This page is only the order.

Who this clone commits and pushes as is **no longer handled here**. It is
`gid`, a separate tool installed once per machine and used in every repository
on it — the problem was never specific to this fork. Its reasoning, including
everything that used to live in `ADR-IDENTITY.md`, is in that project's
`docs/DECISIONS.md`.

## All of it, if you just want the commands

```powershell
npm install -g gid                             # once per machine
gid accounts add makubexD                      # once per machine

git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release

gid fix                                        # once per machine
gid guard on                                   # before the first commit
gid use makubexD
git config --local gid.mirrorBranch master     # master mirrors upstream
gid                                            # must end: OK

.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app start -WithBrowser      # http://localhost:5000
```

---

## 1 — Clone, and switch branch

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release
```

**The checkout is not optional.** The default branch is `master`, a pristine
mirror of upstream that deliberately carries none of this fork's work — no
`contrib/`. A fresh clone lands there and every command below would be "file not
found".

**Check:** `ls contrib` lists `maku.ps1`, `lib`, `commands`, `fork`, `podman`.

You need `git`, PowerShell 7 (`pwsh`) for the app tooling, and Node 20+ for
`gid`. `gh` is optional: without it the git side works fully, but `gh pr create`
and the upstream-CI gate in `fork sync` do not.

## 2 — Make credentials work from anywhere

```powershell
npm install -g gid
gid doctor
```

If it reports that **gh is the credential helper**, repair it:

```powershell
gid fix
```

This removes two entries `gh auth setup-git` wrote to global `.gitconfig`,
handing GitHub back to Git Credential Manager. GCM stores one credential per
account and picks per repository, so nothing needs switching and nothing
prompts. Other repositories on the machine keep working immediately if GCM
already holds their account.

Reversible in one command if you want out: `gh auth setup-git`.

**Check:** `gid doctor` reports the helper as `manager`.

> Skip this only if `gid doctor` already reports `manager`. It is the one step
> that touches global config, and it only ever *removes* entries.

## 3 — Arm the guard, before you commit anything

```powershell
gid guard on
git config --local gid.mirrorBranch master
```

Deliberately **before** step 4. Between cloning and pinning an identity, this
clone inherits the machine's global one — on a work machine that is the work
account, and a commit made in that window is public and permanent. The guard is
what refuses to publish it.

`gid.mirrorBranch` matters here specifically: `master` is a pristine mirror of
upstream, so its pushes carry upstream contributors' addresses legitimately.
Without that key the guard would refuse them, which is the correct default
everywhere else — an exemption that applies by default is how a guard ends up
covering one branch and missing the ones that carry the work.

Hooks are per clone and never committed, so this is per clone, on every machine.
The hook calls the installed `gid`, so it does not go stale when the tool is
updated — and if `gid` cannot be found it refuses the push rather than passing
in silence.

**Check:** `gid` reports `push guard   on`.

## 4 — Tell this clone who it is

```powershell
gid accounts add makubexD     # once per machine
gid use makubexD              # once per clone, instant thereafter
```

`accounts add` asks for a commit name and address, suggesting the account's
public name and its GitHub noreply address. That happens **once per machine**;
every `gid use` afterwards, in any repository, is non-interactive.

`gid use` writes to `.git/config` only. Your global `user.name` and `user.email`
are never modified, and no name or address is ever written into the repository —
which is why this is per clone rather than checked in.

**Check:**

```powershell
gid
```

One block, ending `OK`. Anything else is a refusal that names its own fix.

## 5 — Watch it actually block

Trusting a guard you have not seen work is how people discover it was off.

```powershell
git config --local user.email someone@example.com
git commit --allow-empty -m "should be refused"
git push origin maku-release        # must be REFUSED, naming the commit
```

Then undo it:

```powershell
git reset --hard HEAD~1
gid use makubexD
```

This changes only `user.email`, so a refusal can only have come from the hook —
changing the account as well would make the push fail on *authentication*
before the hook ever ran, which proves nothing.

**If this machine only runs the app and you will never push from it, the git
half is done.** Continue to step 6.

## 6 — Podman

Follow [`../podman/VERIFY.md`](../podman/VERIFY.md) → *Prerequisites*. The one
detail that is easy to get wrong:

```powershell
podman machine init --cpus 4 --memory 4096 --disk-size 60
```

**2 CPUs / 2GB is not enough** once Chrome-based fetching is on, and changing it
later means recreating the machine.

**Check:** `podman info` succeeds.

## 7 — Build and run

```powershell
.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app start -WithBrowser
```

The first build is slow — a large dependency tree over the 9p mount. Later ones
reuse the layer cache.

**Check:** `podman ps --pod` shows `changedetection` and
`browser-sockpuppet-chrome`, both `Up`. Then open <http://localhost:5000>.

## 8 — Prove Chrome is wired up

Containers running is not proof the app knows about the browser.

```powershell
.\contrib\maku.ps1 app verify -WithBrowser
```

It asserts the app can open a socket to Chrome, that `PLAYWRIGHT_DRIVER_URL`
actually reached the container, and that data survives the container being
destroyed — none of which a listening port proves. The UI-level confirmation is
in [`../podman/VERIFY.md`](../podman/VERIFY.md#prove-chrome-is-wired-up).

## Upgrading a clone that predates `gid`

The identity commands used to live in this repository as
`maku.ps1 identity|auth|guard`. They are gone; `gid` replaces all three.

```powershell
git pull
npm install -g gid
gid guard on                                 # replaces the old hook in place
git config --local gid.mirrorBranch master
gid
```

`gid guard on` recognises the PowerShell-era hook as its own, replaces it, and
removes the module copies it left under `.git/fork-guard`. Until you run it,
`gid` reports the guard as `legacy` rather than as `on` — the old hook still
works, but it is checking with logic that is no longer maintained.

It may also mention leftover `.git/fork-identity*.json` from the profile store
that predated even that. Nothing reads them; delete them whenever.

## Afterwards

| You want to | Run |
| --- | --- |
| Get the latest code running | `.\contrib\maku.ps1 app update -WithBrowser` |
| Pull upstream into the fork | `.\contrib\maku.ps1 fork sync` |
| See how far ahead or behind you are | `.\contrib\maku.ps1 fork status` |
| Check who this clone commits as | `gid` |
| Hand the machine back as found | `gid off` then `gid guard off` |

## When a step will not pass

| Symptom | Cause |
| --- | --- |
| `ls contrib` is empty | You are on `master`. `git checkout maku-release` |
| A password prompt on any GitHub repo | gh is the credential helper → step 2 |
| `gid` says the guard is `legacy` | The PowerShell-era hook is still installed → `gid guard on` |
| `gid` says the guard is `foreign` | A `pre-push` hook gid did not write exists; it is left alone |
| `gid` says no local identity | Step 4 not done in *this* clone — it is per clone |
| `gid: command not found` | Node 20+ and `npm install -g gid`; step 2 |
| A push is refused naming upstream authors on `master` | `git config --local gid.mirrorBranch master` — step 3 |
| `origin belongs to X…` | Wrong clone, or wrong account pinned |
| The guard never fires | Per clone: run `gid guard on` here. Also check for `--no-verify` |
| `fork sync` says the tree has uncommitted changes | Commit or stash. Only *tracked* files count, so stray editor config is fine |
| `podman info` fails | The machine is not running: `podman machine start` |
| Watches sit on `Fetching…` | Not a setup problem — see [`../podman/PRICE-TRACKING.md`](../podman/PRICE-TRACKING.md) |
