# Setting up a new machine

From a machine that has never seen this fork, to one that runs the app and can
safely push to it. Written for the Podman box, but nothing here is specific to
it.

Every step has a **check** — something you run that either confirms the step or
tells you what went wrong. Do not move past a failing check; each step assumes
the last one worked.

> Reference docs, once you are set up: [`contrib/fork/README.md`](README.md) for
> the branch model and the tooling, [`contrib/podman/README.md`](../podman/README.md)
> for deployment, [`contrib/podman/GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md) and
> [`GUIDE-AMAZON.md`](../podman/GUIDE-AMAZON.md) for using the app.

---

## The whole thing, if you just want the commands

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release

git config --local user.name  "makubexD"
git config --local user.email "<the fork account's email>"
git config --local credential.https://github.com.username "makubexD"
.\contrib\fork\identity.ps1 -Action save -Profile fork
.\contrib\fork\identity.ps1 -Action install-hook
.\contrib\fork\identity.ps1                       # must print OK [fork]

.\contrib\podman\build.ps1
.\contrib\podman\run.ps1 -WithBrowser             # http://localhost:5000
```

The rest of this page explains what each of those does and how to tell it
worked.

---

## Step 0 — What the machine needs first

| Needed | Why | Check |
| --- | --- | --- |
| **git** | everything | `git --version` |
| **PowerShell 7** (`pwsh`) | what the scripts are tested on | `pwsh -v` |
| **GitHub CLI** (`gh`) | account switching, and reading upstream's CI verdict | `gh --version` |
| **Podman** | only if this machine will *run* the app | Step 5 |

`gh` is optional but you lose two things without it: `identity.ps1` cannot switch
accounts (it will still check the git side and say so), and `sync-fork.ps1`
skips the upstream CI gate with a printed notice.

Windows PowerShell 5.1 will probably work — the pre-push hook explicitly falls
back to it — but PowerShell 7 is what these scripts are tested against.

---

## Step 1 — Clone, and get on the right branch

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release
```

**The `git checkout` is not optional.** The fork's default branch is `master`,
which is a pristine mirror of upstream — it deliberately contains none of this
fork's work, including `contrib/fork/` and `contrib/podman/`. A fresh clone
lands you there, and every command below would be "file not found".

**Check:**

```powershell
git rev-parse --abbrev-ref HEAD     # maku-release
ls contrib\fork                     # identity.ps1, sync-fork.ps1, README.md, this file
```

---

## Step 2 — Tell this clone who you are

This is the step that matters most, because getting it wrong is public and
permanent: a commit authored by your work account, pushed to a public repo, in
history forever.

### 2a. The fork identity

```powershell
git config --local user.name  "makubexD"
git config --local user.email "<the fork account's email>"
git config --local credential.https://github.com.username "makubexD"
.\contrib\fork\identity.ps1 -Action save -Profile fork
```

`--local` matters. It writes to this clone only, so the machine's global git
identity — which on a work laptop is the work account — is untouched, and every
other repository keeps working exactly as before.

The profile is stored in `.git\fork-identity.json`. That is *inside* `.git`, so
it can never be committed. **This is why no identifiers appear anywhere in this
repository**, and why you have to type them once per machine rather than finding
them checked in.

### 2b. The work identity, optional but worth it

If this machine also has a work GitHub account, record it too. Then going back
is one command instead of three, and you will actually do it.

```powershell
git config --local user.name  "<work display name>"
git config --local user.email "<work email>"
git config --local credential.https://github.com.username "<work username>"
.\contrib\fork\identity.ps1 -Action save -Profile work
```

### 2c. Back to the fork identity

Step 2b left the clone configured as the work account. Switch back:

```powershell
.\contrib\fork\identity.ps1 -Action use -Profile fork
```

### 2d. Log `gh` in, if you have it

```powershell
gh auth login          # as the fork account
gh auth status         # both accounts may be listed; the ACTIVE one is what matters
```

**Check:**

```powershell
.\contrib\fork\identity.ps1 -Action list
```

Both profiles should be listed, with `Currently:` showing the fork one.

---

## Step 3 — Make the guard automatic

```powershell
.\contrib\fork\identity.ps1 -Action install-hook
```

Without this, the identity check only runs when you remember to run it. With it,
every `git push` from this clone runs it first.

It has to be done per machine: hooks live in `.git/hooks/`, which git never
commits, so this cannot ship in the repo.

**Check** — prove it actually blocks, rather than trusting that it would:

```powershell
.\contrib\fork\identity.ps1 -Action use -Profile work
git push origin maku-release        # must be REFUSED by the hook
.\contrib\fork\identity.ps1 -Action use -Profile fork
```

If you have no `work` profile, skip this — but then verify the guard some other
way before trusting it.

---

## Step 4 — Prove the git side is safe

```powershell
.\contrib\fork\identity.ps1
```

Expect one line:

```
OK [fork]: makubexD <...>  gh:makubexD  (C:\path\to\changedetection.io)
```

Anything else is a refusal that names its own fix. The four it can raise:

| Refusal | What to do |
| --- | --- |
| `WRONG user.name / user.email / credential username` | `-Action use -Profile fork` |
| `WRONG GH ACCOUNT` | same command — it switches `gh` too |
| `ORIGIN ... does not belong to` | you cloned someone else's copy |
| `UPSTREAM PUSH IS NOT DISABLED` | `git remote set-url --push upstream DISABLED` |

That last one will not appear yet — a fresh clone has no `upstream` remote at
all. `sync-fork.ps1` adds it the first time you run it, and disables pushing to
it in the same breath, because a remote added without a push URL pushes to its
*fetch* URL, which here is `dgtlmoon/changedetection.io` itself.

**If this machine only runs the app and you will never push from it, you are
done with the git half.** Skip to Step 5.

---

## Step 5 — Podman

Follow [`contrib/podman/README.md`](../podman/README.md) → *Windows: Podman
Desktop + WSL2*. Summarised, because one detail is easy to get wrong:

```powershell
# elevated PowerShell, once; reboot afterwards
wsl --install --no-distribution

winget install RedHat.Podman-Desktop

podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
```

**2 CPUs / 2GB is not enough** once Chrome-based fetching is on. Set the size at
`init` time; changing it later means recreating the machine.

**Check:**

```powershell
podman info        # must succeed before anything below will work
```

---

## Step 6 — Build and run

```powershell
.\contrib\podman\build.ps1
.\contrib\podman\run.ps1 -WithBrowser
```

The first build is slow — it installs a large dependency tree over the 9p mount
into the Windows filesystem. Later builds reuse the layer cache.

`-WithBrowser` starts real Chrome (`sockpuppetbrowser`) alongside the app in one
pod, which is what JS-rendered pages, prices, Browser Steps and the Visual
Selector all need.

**Check:**

```powershell
podman ps --pod --format "{{.Names}}  {{.Status}}"
```

Both `changedetection` and `browser-sockpuppet-chrome`, both `Up`. Then open
<http://localhost:5000>.

---

## Step 7 — Prove Chrome is actually wired up

The containers running is not proof the app *knows* about the browser.

```powershell
podman exec changedetection sh -c 'echo $PLAYWRIGHT_DRIVER_URL'
```

Must print `ws://localhost:3000`. Nothing means the app has no browser.

Then in the UI — this is the real proof — add any watch, open **Edit** → the
**Request** tab (not General), and read **Fetch Method**. Three radios; the
middle one must say:

```
Playwright Chromium/Javascript via 'ws://localhost:3000'
```

`WebDriver Chrome/Javascript` with no URL after it means the app never received
the driver URL. Full walkthrough with figures:
[`GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md).

---

## Step 8 — Day to day

| You want to | Run |
| --- | --- |
| Get the latest code running | `.\contrib\podman\update.ps1 -WithBrowser` |
| See why something is wrong | `.\contrib\podman\logs.ps1` / `-Browser` |
| Pull upstream's new commits into the fork | `.\contrib\fork\sync-fork.ps1` |
| Check who you are before pushing | `.\contrib\fork\identity.ps1` |

`update.ps1` is the everyday one: it fast-forwards the branch you are on,
rebuilds **only** if the pull touched something the image actually contains, and
restarts. It never merges, never switches branch, never pushes — safe on a
machine that only deploys.

`sync-fork.ps1` is the opposite job and belongs on a machine where you work:
it merges and it pushes. You do not need it here unless you commit here.

---

## Step 9 — Handing the machine back

If this is a work laptop and you want it exactly as you found it:

```powershell
.\contrib\fork\identity.ps1 -Action restore
```

That undoes the identity changes — including `gh`'s active account, the one
genuinely machine-wide thing any of this touches — and unsets keys that were
unset before rather than writing values over them. Global git config was never
modified in the first place.

To also drop the push guard:

```powershell
.\contrib\fork\identity.ps1 -Action uninstall-hook
```

The containers and the `changedetection-data` volume are separate; remove those
through Podman when you actually want the watches gone.

---

## When a step will not pass

| Symptom | Cause |
| --- | --- |
| `identity.ps1` : "No profiles configured yet" | Step 2 not done in *this* clone. Profiles are per-clone by design |
| `identity.ps1` : "WRONG GH ACCOUNT" but git config looks right | `gh`'s active account is global and separate. `-Action use -Profile fork` sets both |
| `-Action use` warns it could not switch `gh` | That account is not logged in here: `gh auth login -u <name>` |
| `sync-fork.ps1` : "Working tree is not clean" | Commit or stash first. Untracked local config counts — put it in `.git/info/exclude` |
| `sync-fork.ps1` : "master has N local commit(s)" | Something was committed to the mirror. Move it to a `feat/*` branch and reset `master` |
| The hook never fires | It is per-clone: `-Action install-hook` on *this* machine. Also check you are not using `--no-verify` |
| `git push` fails on credentials, not on the hook | Wrong `credential.https://github.com.username`. The hook runs after git contacts the remote, so an auth failure comes first |
| `ls contrib\fork` is empty | You are on `master`. `git checkout maku-release` |
| Watches sit on `Fetching…` forever | Not a setup problem — see [`GUIDE-TOUS.md`](../podman/GUIDE-TOUS.md) |
