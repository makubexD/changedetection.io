# Setting up a machine

From a machine that has never seen this fork to one that is sending you alerts.

Two tracks. Do **Part 1** always; do **Part 2** only if you will commit from this
machine.

| Track | Steps | For |
| --- | --- | --- |
| **Part 1 — run it** | 1–6 | A rebuilt sandbox, a fresh laptop, anyone who just wants the app working |
| **Part 2 — push from it** | 7–10 | A clone you will commit and push from |

Every step has a **check**. Do not move past a failing one — each assumes the
last worked.

> **Part 1 makes no commits.** If you will ever commit from this machine, finish
> Part 2 *before your first commit*: until then the clone inherits the machine's
> global identity, and on a work machine that is the work account. Such a commit
> to this public fork is permanent.

## All of it, if you just want the commands

```powershell
# Part 1 — run it
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release                      # not optional - see step 2
.\contrib\maku.ps1 app build                   # slow the first time
.\contrib\maku.ps1 app start -WithBrowser      # http://localhost:5000
.\contrib\maku.ps1 app verify -WithBrowser     # must end PASSED

# Part 2 — only if you will push from here
npm install -g gid                             # once per machine
gid accounts add makubexD                      # once per machine
gid fix                                        # once per machine
gid guard on                                   # BEFORE the first commit
gid use makubexD
git config --local gid.mirrorBranch master     # master mirrors upstream
gid                                            # must end: OK
```

> **Before you wipe a sandbox, save the watches.** Every watch, filter and
> snapshot lives in one volume, and nothing else on the machine has a copy:
> ```powershell
> podman volume export changedetection-data -o backup.tar
> podman volume import changedetection-data backup.tar   # after rebuilding
> ```

---

# Part 1 — Run it

## 1 — Podman

Podman on Windows runs a Linux VM on WSL2, so WSL has to exist first. Installing
it is the **only step needing administrator rights**.

```powershell
# elevated PowerShell, once
wsl --install --no-distribution
```

Then **reboot** — WSL is not usable until you do. Afterwards, from a normal
PowerShell:

```powershell
wsl --status                              # version info, not "not installed"
winget install RedHat.Podman-Desktop
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start
```

**2 CPUs / 2GB is not enough** once Chrome-based fetching is on, and changing it
later means recreating the machine.

On **Linux**: install Podman from your distribution (`dnf install podman`,
`apt install podman`). No VM, no `podman machine`.

**Check:** `podman info` succeeds. Nothing below works until it does.

## 2 — Clone, and switch branch

```powershell
git clone https://github.com/makubexD/changedetection.io.git
cd changedetection.io
git checkout maku-release
```

**The checkout is not optional.** The default branch is `master`, a pristine
mirror of upstream carrying none of this fork's work — no `contrib/`. A fresh
clone lands there and every command below would be "file not found".

You also need PowerShell 7 (`pwsh`). Node 20+ and `gh` are Part 2 only.

**Check:** `ls contrib` lists `maku.ps1`, `lib`, `commands`, `fork`, `podman`.

## 3 — Build and run

```powershell
.\contrib\maku.ps1 app build
.\contrib\maku.ps1 app start -WithBrowser
```

The first build takes several minutes and prints nothing while it pulls the base
image and installs requirements. It has not hung.

`-WithBrowser` adds real Chrome, for pages that render their content in
JavaScript. Skip it if you know you do not need it — step 5 says how to tell.

**Check:** `podman ps --pod` shows `changedetection` and
`browser-sockpuppet-chrome`, both `Up`. Open <http://localhost:5000>.

## 4 — Prove it works

Containers running is not proof the app knows about the browser, or that it will
keep your data.

```powershell
.\contrib\maku.ps1 app verify -WithBrowser
```

It uses its own containers and volume, so it cannot disturb the deployment. It
asserts the app can open a socket to Chrome, that `PLAYWRIGHT_DRIVER_URL` reached
the container, that this fork's runtime patches are live, and that the datastore
survives the container being destroyed — none of which a listening port proves.

**Check:** it ends `DEPLOYMENT CHECK PASSED`. What each stage means, and the
UI-level Fetch Method check, are in [`../podman/VERIFY.md`](../podman/VERIFY.md).

## 5 — Create your watches

Full recipes in [`../podman/WATCHING.md`](../podman/WATCHING.md). The shape you
need depends on one question — **does the page publish its price as structured
data?** Ask the app, do not guess:

```powershell
.\contrib\maku.ps1 site probe -Url <the page> -Selector '<css, optional>'
```

| It answers | Use |
| --- | --- |
| a price under "Restock & Price mode would find" **and that is the number you want** | **Restock & Price** processor, no filter |
| a price you do **not** want, or none | **Text** processor + a CSS filter on the element |

It also tells you whether the value arrived over plain HTTP — if it did, that
watch does not need Chrome, and turning it off saves memory and latency.

**tucambista.pe is the second case** and is worked through in
[`../podman/SITE-NOTES.md`](../podman/SITE-NOTES.md): one Text watch per rate,
Basic fast Plaintext/HTTP Client, and these filters —

| Rate | CSS filter |
| --- | --- |
| Compra | `.tc-quote-rates button:nth-of-type(1) .tc-quote-rate-value span:first-child` |
| Venta | `.tc-quote-rates button:nth-of-type(2) .tc-quote-rate-value` |

**Check:** the watch's row shows a **Text** or **Restock** badge and a
`CHECKED` time, with no red error.

## 6 — Get notified

**There is no browser pop-up.** The app has no web push at all — the in-app
badge only counts unread changes while the tab is open. Alerts leave the machine
through Apprise, and the desktop schemes cannot reach your desktop from inside a
container. Telegram is the setup below.

1. In Telegram, message **@BotFather** → `/newbot` → copy the **token**.
2. **Message your new bot once.** A bot cannot open a conversation, so without
   this there is no chat to send to.
3. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` and read
   `message.chat.id`.
4. In the app: **Settings → Notifications** → Notification URL:
   ```
   tgram://<TOKEN>/<CHAT_ID>
   ```
   It must be your own chat id, not another bot's.
5. Set **Notification format** to **Plain Text**. `tgram://` supports only very
   limited HTML and fails when extra tags are sent.
6. Paste this body — it names the direction instead of leaving you to compare
   two numbers:

   ```jinja
   {{ watch_title }}
   {%- set before = diff_changed_from | trim -%}
   {%- set after  = diff_changed_to   | trim -%}
   {% if before and after and before | float %}
   {{ 'UP' if after | float > before | float else 'DOWN' }}   {{ before }} -> {{ after }}
   change: {{ ((after | float - before | float) / (before | float) * 100) | round(2) }}%
   {% else %}
   {{ diff }}
   {% endif %}
   {{ watch_url }}
   ```

   Why it is trustworthy here, when a numeric **Condition** on the same page is
   not: this arithmetic is Jinja's `| float`, which reads `3.344` as `3.344`.
   `extracted_number` uses `price_parser`, which reads it as `3344` —
   [`WATCHING.md`](../podman/WATCHING.md#a-condition-on-extracted_number-never-fires).

**Check:** open a watch → **Notifications** → **Send test notification**. With
two or more snapshots it renders the watch's *real* last two, so the message
should name both actual values and say `UP` or `DOWN`. Example sentences instead
mean that watch has fewer than two snapshots yet — recheck it and try again.

---

# Part 2 — Push from it

Only for a clone you will commit from. Identity is handled by `gid`, a separate
tool used in every repository on the machine — the problem was never specific to
this fork. Its reasoning is in that project's `docs/DECISIONS.md`.

## 7 — Make credentials work from anywhere

```powershell
npm install -g gid
gid doctor
```

If it reports that **gh is the credential helper**, repair it with `gid fix`.
That removes two entries `gh auth setup-git` wrote to global `.gitconfig`,
handing GitHub back to Git Credential Manager, which stores one credential per
account and picks per repository — so nothing needs switching and nothing
prompts. Reversible with `gh auth setup-git`.

**Check:** `gid doctor` reports the helper as `manager`.

## 8 — Arm the guard, before you commit anything

```powershell
gid guard on
git config --local gid.mirrorBranch master
```

**Deliberately before step 9.** Between cloning and pinning an identity this
clone uses the machine's global one; a commit made in that window is public and
permanent. The guard is what refuses to publish it.

`gid.mirrorBranch` matters because `master` mirrors upstream, so its pushes carry
upstream contributors' addresses legitimately. Without that key the guard would
refuse them — and an exemption that applied by default is how a guard ends up
covering one branch and missing the ones carrying the work.

Hooks are per clone and never committed, so this is per clone on every machine.
The hook calls the installed `gid`, so it cannot go stale, and refuses the push
rather than passing silently if `gid` is missing.

**Check:** `gid` reports `push guard   on`.

## 9 — Tell this clone who it is

```powershell
gid accounts add makubexD     # once per machine
gid use makubexD              # once per clone
```

`accounts add` asks for a commit name and address once per machine; every
`gid use` afterwards is non-interactive. It writes to `.git/config` only — your
global `user.name` and `user.email` are never modified, and no address is ever
written into the repository.

**Check:** `gid` prints one block ending `OK`. Anything else is a refusal that
names its own fix.

## 10 — Watch it actually block

Trusting a guard you have not seen work is how people discover it was off.

```powershell
git config --local user.email someone@example.com
git commit --allow-empty -m "should be refused"
git push origin maku-release        # must be REFUSED, naming the commit

git reset --hard HEAD~1             # then undo it
gid use makubexD
```

Only `user.email` changes, so a refusal can only have come from the hook —
changing the account as well would fail on *authentication* before the hook ran,
which proves nothing.

---

## Upgrading a clone that predates `gid`

The identity commands used to live here as `maku.ps1 identity|auth|guard`. They
are gone; `gid` replaces all three.

```powershell
git pull
npm install -g gid
gid guard on                                 # replaces the old hook in place
git config --local gid.mirrorBranch master
gid
```

`gid guard on` recognises the PowerShell-era hook as its own, replaces it, and
removes the module copies under `.git/fork-guard`. Until then `gid` reports the
guard as `legacy`: the old hook still works, but on unmaintained logic. It may
also mention leftover `.git/fork-identity*.json`; nothing reads them, delete them
whenever.

## Afterwards

| You want to | Run |
| --- | --- |
| Get the latest code running | `.\contrib\maku.ps1 app update -WithBrowser` |
| Save the watches before wiping anything | `podman volume export changedetection-data -o backup.tar` |
| Pull upstream into the fork | `.\contrib\maku.ps1 fork sync` |
| See how far ahead or behind you are | `.\contrib\maku.ps1 fork status` |
| Check who this clone commits as | `gid` |
| Hand the machine back as found | `gid off` then `gid guard off` |

## When a step will not pass

| Symptom | Cause |
| --- | --- |
| `podman info` fails | The machine is not running: `podman machine start` |
| `ls contrib` is empty | You are on `master`. `git checkout maku-release` |
| `app start` says the image does not exist | Step 3's `app build` has not run, or `-Image` is misspelt |
| `app start` says something else is serving the port | Another app holds it. Stop it, or `-Port 5001` |
| Watch row sits on `Fetching…` | Not a setup problem — [`../podman/WATCHING.md`](../podman/WATCHING.md) |
| Test notification arrives with example sentences | That watch has fewer than two snapshots. Recheck it |
| No notification at all | Wrong chat id, or you never messaged the bot — step 6.2 |
| A password prompt on any GitHub repo | gh is the credential helper → step 7 |
| `gid: command not found` | Node 20+ and `npm install -g gid` → step 7 |
| `gid` says the guard is `legacy` | The PowerShell-era hook is still installed → `gid guard on` |
| `gid` says the guard is `foreign` | A `pre-push` hook gid did not write exists; it is left alone |
| `gid` says no local identity | Step 9 not done in *this* clone — it is per clone |
| A push is refused naming upstream authors on `master` | `git config --local gid.mirrorBranch master` → step 8 |
| `origin belongs to X…` | Wrong clone, or wrong account pinned |
| The guard never fires | Per clone: run `gid guard on` here. Also check for `--no-verify` |
| `fork sync` says the tree has uncommitted changes | Commit or stash. Only *tracked* files count |
