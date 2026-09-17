# Setting up a machine

From a machine that has never seen this fork, to one that runs the app and can
safely push to it.

Every step has a **check**. Do not move past a failing one — each step assumes
the last worked. *Why* any of it works this way is in
[`IDENTITY.md`](IDENTITY.md) and [`ADR-IDENTITY.md`](ADR-IDENTITY.md); this page
is only the order.

## All of it, if you just want the commands

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release

.\contrib\maku.ps1 auth repair                 # once per machine
.\contrib\maku.ps1 guard enable                # before the first commit
.\contrib\maku.ps1 identity init makubexD
.\contrib\maku.ps1 identity show               # must end: OK

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

You need `git` and PowerShell 7 (`pwsh`). `gh` is optional: without it the git
side works fully, but `gh pr create` and the upstream-CI gate in `fork sync` do
not.

## 2 — Make credentials work from anywhere

```powershell
.\contrib\maku.ps1 auth show
```

If it reports that **gh is the credential helper**, repair it:

```powershell
.\contrib\maku.ps1 auth repair
```

This removes two entries `gh auth setup-git` wrote to global `.gitconfig`,
handing GitHub back to Git Credential Manager. GCM stores one credential per
account and picks per repository, so nothing needs switching and nothing
prompts. Other repositories on the machine keep working immediately if GCM
already holds their account.

Reversible in one command if you want out: `gh auth setup-git`.

**Check:** `.\contrib\maku.ps1 auth show` reports the helper as `manager`.

> Skip this only if `auth show` already reports `manager`. It is the one step
> that touches global config, and it only ever *removes* entries — see
> [`ADR-IDENTITY.md`](ADR-IDENTITY.md) §1.

## 3 — Arm the guard, before you commit anything

```powershell
.\contrib\maku.ps1 guard enable
```

Deliberately **before** step 4. Between cloning and pinning an identity, this
clone inherits the machine's global one — on a work machine that is the work
account, and a commit made in that window is public and permanent. The guard is
what refuses to publish it.

Hooks are per clone and never committed, so this is per machine. Run it again
after pulling a change to the tooling: the guard runs its own copies under
`.git/fork-guard`, which do not re-sync by themselves. `identity show` compares
them against `contrib/lib` and reports `drifted` when they no longer match, so
you are told rather than left guessing.

**Check:** `.\contrib\maku.ps1 identity show` reports `push guard   on`.

## 4 — Tell this clone who it is

```powershell
.\contrib\maku.ps1 identity init makubexD
```

It asks for a commit name and address, pre-filled from what the clone already
has and then from the GitHub profile. Enter accepts the suggestion. Pass
`-Name` and `-Email` to skip the questions entirely.

This writes to `.git/config` only. Your global `user.name` and `user.email` are
never modified, and no name or address is ever written into the repository —
which is why this is per clone rather than checked in.

**Check:**

```powershell
.\contrib\maku.ps1 identity show
```

One block, ending `OK`. Anything else is a refusal that names its own fix.
[What it can refuse, and why](IDENTITY.md#what-it-refuses-and-why).

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
.\contrib\maku.ps1 identity init makubexD
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

## Upgrading a clone that predates this tooling

```powershell
git pull
.\contrib\maku.ps1 guard enable      # the old hook points at files that are gone
.\contrib\maku.ps1 identity show
```

The old hook exits 0 when it cannot find its checker, so until you re-run
`guard enable` **every push passes unchecked**. `identity show` reports that
state as `stale` rather than as merely off.

It may also mention leftover `.git/fork-identity*.json` from the old profile
store. Nothing reads them; delete them whenever.

## Afterwards

| You want to | Run |
| --- | --- |
| Get the latest code running | `.\contrib\maku.ps1 app update -WithBrowser` |
| Pull upstream into the fork | `.\contrib\maku.ps1 fork sync` |
| See how far ahead or behind you are | `.\contrib\maku.ps1 fork status` |
| Hand the machine back as found | `.\contrib\maku.ps1 identity reset` then `guard disable` |

## When a step will not pass

| Symptom | Cause |
| --- | --- |
| `ls contrib` is empty | You are on `master`. `git checkout maku-release` |
| A password prompt on any GitHub repo | gh is the credential helper → step 2 |
| `identity show` says the guard is `stale` | The hook predates this tooling, or a file under `.git/fork-guard` is missing → `guard enable` |
| `identity show` says the guard is `drifted` | `contrib/lib` changed since the guard was installed → `guard enable` |
| `identity show` says no local identity | Step 4 not done in *this* clone — it is per clone |
| `origin belongs to X…` | Wrong clone, or wrong account pinned |
| `guard enable` refuses | A `pre-push` hook this tool did not write exists; it is left alone |
| The guard never fires | Per clone: run `guard enable` here. Also check for `--no-verify` |
| `fork sync` says the tree has uncommitted changes | Commit or stash. Only *tracked* files count, so stray editor config is fine |
| `podman info` fails | The machine is not running: `podman machine start` |
| Watches sit on `Fetching…` | Not a setup problem — see [`../podman/PRICE-TRACKING.md`](../podman/PRICE-TRACKING.md) |
