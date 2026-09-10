# Fork maintenance

Tooling for keeping this fork in step with `dgtlmoon/changedetection.io`.

**This directory exists only on `maku-release`.** It is fork-specific by nature —
it names this fork's branches and its upstream — so it is deliberately kept off
`master` (a pristine mirror) and off the `feat/*` branches, which are written to
be proposable upstream unchanged.

| File | What it does |
| --- | --- |
| `sync-fork.ps1` | Fetch upstream → fast-forward `master` → merge `master` into `maku-release` → push both |
| `identity.ps1` | Switch this clone between GitHub accounts, guard pushes, and put the machine back as found |
| [`NEW-MACHINE.md`](NEW-MACHINE.md) | **Start here on a machine that has never seen this fork** — ordered setup, with a check after every step |

```powershell
.\contrib\fork\sync-fork.ps1
```

Run it from anywhere inside the repo. It adds the `upstream` remote if the clone
does not have one, so a fresh `git clone` of the fork works with no setup.

## Identities — `identity.ps1`

Most people who work on this fork also have a work GitHub account on the same
machine. Committing here as that account is the mistake this script exists to
prevent.

```powershell
.\contrib\fork\identity.ps1                    # check — run before pushing
.\contrib\fork\identity.ps1 -Action list
.\contrib\fork\identity.ps1 -Action save    -Profile fork
.\contrib\fork\identity.ps1 -Action use     -Profile fork
.\contrib\fork\identity.ps1 -Action restore
```

### No identifiers are in this repo, on purpose

This fork is **public**. A name, an email or a username committed here is
published permanently — history, forks, mirrors, scrapers. So `identity.ps1`
contains none of them. Profiles live in `.git\fork-identity.json`, which is
inside `.git` and therefore cannot be committed even by accident.

`save` writes that file from whatever is configured right now, so bootstrapping
a machine is: set the identity once, save it under a name, done.

### Setting up a new machine

```powershell
# 1. the fork identity, saved as the profile the guard checks against
git config --local user.name  "makubexD"
git config --local user.email "you@example.com"
git config --local credential.https://github.com.username "makubexD"
.\contrib\fork\identity.ps1 -Action save -Profile fork

# 2. optional: record the machine's own work identity too, so switching back
#    to it is one command rather than four
git config --local user.name  "Work Name"
git config --local user.email "work@example.com"
git config --local credential.https://github.com.username "work-username"
.\contrib\fork\identity.ps1 -Action save -Profile work

# 3. back to the fork identity, and confirm
.\contrib\fork\identity.ps1 -Action use -Profile fork
.\contrib\fork\identity.ps1
```

Profile names are free-form; `fork` is the only one that matters, because that
is what `check` verifies against unless you pass `-Profile`.

### What it will and will not touch

**It only ever writes repo-local git config.** Your global `user.name` and
`user.email` are never modified, so every other repository on the machine
carries on exactly as before. That matters more than it sounds: on a machine
whose *global* identity is the work account, the fork identity has to be a
local override, and the global one has to survive untouched.

**The one machine-wide thing is `gh`'s active account**, which is global by
design — there is no per-repository version of it. So the first `use` snapshots
the whole prior state before changing anything:

| Snapshotted | Restored by `-Action restore` |
| --- | --- |
| repo-local `user.name`, `user.email`, credential username | set back, **or unset again if they were unset** |
| `gh`'s active account | switched back |

The snapshot is taken **once** and never overwritten, so a second switch cannot
record the first switch's state as "original". `restore` clears it afterwards,
so the next switch starts a fresh one. Restoring an unset key as *unset* rather
than as an empty string is the part that keeps a machine genuinely untouched — a
clone that inherited its identity from global config goes back to inheriting it.

Never switched this clone? `restore` says so and changes nothing.

### What `check` refuses

It is the guard to run before pushing, and it fails closed:

| Refusal | Why it matters |
| --- | --- |
| Name, email or credential username is not the profile's | The commit would carry the wrong author, permanently and publicly |
| `gh`'s active account is not the profile's | The commit is fine but the **push** goes out as the wrong account |
| `origin` does not belong to the profile's account | Right identity, wrong destination |
| `upstream` has a push URL other than `DISABLED` | A push could reach `dgtlmoon/changedetection.io` itself |
| No profiles configured yet | It refuses rather than assuming the current identity is correct |

### Making the guard automatic

`check` only protects the pushes you remember to run it before. Install the
pre-push hook and it protects all of them, including a `git push` typed from an
editor's UI:

```powershell
.\contrib\fork\identity.ps1 -Action install-hook
.\contrib\fork\identity.ps1 -Action uninstall-hook
```

```
git push  ->  pre-push hook  ->  identity.ps1 -Action check  ->  allowed / blocked
```

Worth knowing about it:

- **It lives in `.git/hooks/`**, which is per-clone and never committed. That is
  why it has to be installed on each machine rather than shipped in the repo.
- **It does not block a push from a branch without `contrib/fork/`.** `master`
  is a pristine mirror of upstream and has no such directory; blocking its push
  would break `sync-fork.ps1`, which pushes `master` as step 2. `sync-fork.ps1`
  runs the check up front instead, so that path stays covered.
- **`git push --no-verify` bypasses it** for one push, which is the intended
  escape hatch.
- **It refuses to overwrite a `pre-push` hook it did not write**, and
  `uninstall-hook` refuses to delete one.
- It is written with LF line endings whatever this file was checked out as —
  `sh` rejects a CRLF script with "bad interpreter".

### How the pieces fit

| Situation | What runs the check |
| --- | --- |
| `sync-fork.ps1` | Calls `identity.ps1 -Action check` itself, before anything is pushed. Refuses if the script is missing; `-SkipIdentityCheck` overrides |
| Any `git push` | The pre-push hook, once installed |
| Anything else | `.\contrib\fork\identity.ps1` by hand |

## The branch model it assumes

| Branch | Role |
| --- | --- |
| `master` | The single pristine mirror of `upstream/master`, and the fork's **default branch**. Never commit to it |
| `maku-release` | The integration and release branch. All work lands here; CI builds it and deployments come from it |
| `feat/*` | Cut from `master`, merged into `maku-release` |

`master` is the default branch on purpose: GitHub's **Sync fork** button targets
the default branch, and because nothing but a fast-forward ever lands there, it
always succeeds. That also makes step 2 of the script a guaranteed
fast-forward — one local commit on `master` and every future sync would need
conflict resolution instead.

`maku-release` is **merged into, never rebased**. Rebasing would flatten its
merge commits and rewrite every SHA, which means force-pushing the branch that
CI builds and deployments pin. Rebase a `feat/*` branch instead, before merging
it.

## About "N commits ahead, M commits behind"

On `maku-release`, GitHub's branch page shows:

> This branch is **51 commits ahead of**, **0 commits behind**
> dgtlmoon/changedetection.io:master

Only one of those numbers is a problem, and they are worth separating:

| Number | What it means | Can it be zero? |
| --- | --- | --- |
| **behind** | Upstream has commits this branch has not taken | **Yes — and it should be.** That is this script's job |
| **ahead** | This branch has commits upstream does not have | **No.** Those are the fork's own work |

A fork that carries changes is ahead of upstream by definition; the only way to
show `0 ahead` is to carry nothing. So "ahead" is not a warning, it is the
inventory. Chasing it would mean deleting the fork's reason to exist.

"Behind", on the other hand, is real drift, and it compounds: the longer it
runs, the more likely the eventual merge conflicts. Run the script whenever the
number is non-zero.

The fork's default branch (`master`) shows `0 ahead, 0 behind` after a sync,
because it is a mirror and holds nothing of its own.

## What the script refuses to do

It stops rather than guessing, in four places:

- **Dirty working tree** — the branch switches would otherwise fail halfway and
  leave you on an unexpected branch.
- **`master` has local commits** — it has stopped being a clean mirror, and the
  fast-forward that every future sync depends on is already broken. The message
  says to move them to a `feat/*` branch.
- **Upstream CI is not green on the target commit** — this fork disables
  upstream's ~50-job test matrix rather than re-running it (a fork that adds
  `contrib/` cannot fix a failure in it, and inherits every upstream flake for
  nothing), so it reads upstream's own verdict via `gh api` instead. Override
  with `-SkipUpstreamCiCheck` when you mean to.
- **A merge conflict** — the fork patches exactly one upstream-owned file, the
  fork guard in `.github/workflows/containers.yml`. A conflict anywhere else
  means something new is being carried, which is worth questioning before
  resolving.

Two checks degrade instead of failing, so the script still works on a machine
that only deploys: if `gh` is not installed the CI gate is skipped with a
notice, and if the identity guard is not found beside the repo it prints the
committer identity instead of verifying it. Both say so out loud rather than
staying quiet.

Upstream's tags are fetched but never pushed — they would trigger this fork's
tag-gated publishing workflows.

## Not to be confused with

[`contrib/podman/update.ps1`](../podman/update.ps1) pulls the branch you already
have checked out and restarts the app. It never merges, switches branch or
pushes. That one is for a machine that only runs the app; this one is for the
machine where the work happens.
