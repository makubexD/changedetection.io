# Setting up a new machine

From a machine that has never seen this fork, to one that runs the app and can
safely push to it.

Every step has a **check**. Do not move past a failing one — each step assumes
the last worked. Why any of it works the way it does is in
[`README.md`](README.md); this page is only the order.

## All of it, if you just want the commands

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release

.\contrib\fork\identity.ps1 capture work          # how this machine is now
.\contrib\fork\identity.ps1 define fork -From work
.\contrib\fork\identity.ps1 use fork
.\contrib\fork\identity.ps1 protect
.\contrib\fork\identity.ps1                       # must print OK [fork]

.\contrib\podman\build.ps1
.\contrib\podman\run.ps1 -WithBrowser             # http://localhost:5000
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
`contrib/fork/`, no `contrib/podman/`. A fresh clone lands there and every
command below would be "file not found".

**Check:** `ls contrib\fork` lists four files.

You need `git` and PowerShell 7 (`pwsh`). `gh` is optional: without it,
`identity.ps1` still checks and sets the git side but cannot switch gh's
account, and `sync-fork.ps1` skips its upstream CI gate. Both say so when it
happens.

## 2 — Tell this clone who you are

Getting this wrong is public and permanent: a commit authored by your work
account, in a public repo, in history forever.

```powershell
.\contrib\fork\identity.ps1 capture work
```

That saves the machine's **current** identity — whatever git is already
configured to use here, global config included — under the name `work`. Nothing
to type.

```powershell
.\contrib\fork\identity.ps1 define fork -From work
```

That asks three questions, each pre-filled from `work`. Enter keeps the value
shown, typing replaces it, `-` clears it:

```
  Commit name      [Your Work Name]: makubexD
  Commit email     [you@work.example]: <the fork account's email>
  GitHub username  [your-work-user]  (gh knows: makubexD, your-work-user): makubexD
```

Then switch to it:

```powershell
.\contrib\fork\identity.ps1 use fork
```

If `gh` is installed, log the fork account in once so `use` can switch to it:
`gh auth login`.

**Check:** `.\contrib\fork\identity.ps1 list` shows both profiles, with
`active` on the fork one.

> Profiles are written to `.git\fork-identity.json` — inside `.git`, so they can
> never be committed. That is why nothing is checked in and why you type this
> once per machine.

## 3 — Make the check automatic

```powershell
.\contrib\fork\identity.ps1 protect
```

Without it the identity check only runs when you remember. With it, every
`git push` from this clone runs it first. Hooks are per-clone and never
committed, so this is per machine.

**Check** — watch it actually block, rather than trusting that it would:

```powershell
.\contrib\fork\identity.ps1 use work
git push origin maku-release        # must be refused
.\contrib\fork\identity.ps1 use fork
```

## 4 — Prove the git side is safe

```powershell
.\contrib\fork\identity.ps1
```

One line: `OK [fork]: ...`. Anything else is a refusal that names its own fix on
a `fix:` line. [What it can refuse, and why](README.md#what-check-refuses).

**If this machine only runs the app and you will never push from it, the git
half is done.** Continue to step 5.

## 5 — Podman

Follow [`contrib/podman/README.md`](../podman/README.md) → *Windows: Podman
Desktop + WSL2*. The one detail that is easy to get wrong:

```powershell
podman machine init --cpus 4 --memory 4096 --disk-size 60
```

**2 CPUs / 2GB is not enough** once Chrome-based fetching is on, and changing it
later means recreating the machine.

**Check:** `podman info` succeeds.

## 6 — Build and run

```powershell
.\contrib\podman\build.ps1
.\contrib\podman\run.ps1 -WithBrowser
```

The first build is slow — a large dependency tree over the 9p mount. Later ones
reuse the layer cache.

**Check:** `podman ps --pod` shows `changedetection` and
`browser-sockpuppet-chrome`, both `Up`. Then open <http://localhost:5000>.

## 7 — Prove Chrome is wired up

Containers running is not proof the app knows about the browser.

```powershell
podman exec changedetection sh -c 'echo $PLAYWRIGHT_DRIVER_URL'
```

Must print `ws://localhost:3000`.

Then in the UI: add a watch → **Edit** → the **Request** tab (not General) →
**Fetch Method**. Three radios; the middle one must read `Playwright
Chromium/Javascript via 'ws://localhost:3000'`. If it says `WebDriver
Chrome/Javascript` with no URL, the app never got the driver URL. Figures and
the full walkthrough: [`GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md).

## Afterwards

| You want to | Run |
| --- | --- |
| Get the latest code running | `.\contrib\podman\update.ps1 -WithBrowser` |
| Pull upstream into the fork | `.\contrib\fork\sync-fork.ps1` |
| Hand the machine back as found | `.\contrib\fork\identity.ps1 restore` |

`restore` undoes the identity changes, gh's active account included, and unsets
keys that were unset rather than writing over them. Global git config was never
modified. Add `unprotect` to drop the push guard too.

## When a step will not pass

| Symptom | Cause |
| --- | --- |
| `ls contrib\fork` is empty | You are on `master`. `git checkout maku-release` |
| "Expected this clone to have identity profiles" | Step 2 not done in *this* clone — profiles are per-clone |
| "Expected gh to be signed in as…" but git config looks right | gh's account is global and separate; another terminal changed it. `use fork` sets both |
| `use` warns it could not switch gh | That account is not logged in here: `gh auth login -u <name>` |
| `define` says it needs an interactive console | Configure with `git config` and use `capture <name>` instead |
| "Expected upstream pushes to be DISABLED" | `git remote set-url --push upstream DISABLED` |
| `sync-fork.ps1` says the tree is not clean | Commit or stash. Untracked local config counts — put it in `.git/info/exclude` |
| The hook never fires | Per-clone: run `protect` on *this* machine. Also check for `--no-verify` |
| `git push` fails on credentials, not the hook | Wrong credential username. git contacts the remote before the hook runs, so auth fails first |
| Watches sit on `Fetching…` | Not setup — see [`GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md) |
