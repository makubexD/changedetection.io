# Fork maintenance

Tooling for keeping this fork in step with `dgtlmoon/changedetection.io`, and for
making sure it is pushed to by the right account.

**This directory exists only on `maku-release`.** It names this fork's branches
and its upstream, so it is kept off `master` (a pristine mirror) and off the
`feat/*` branches, which are written to be proposable upstream unchanged.

| File | What it is |
| --- | --- |
| **[`NEW-MACHINE.md`](NEW-MACHINE.md)** | **Start here on a machine that has never seen this fork.** The ordered setup path |
| [`GITHUB-CI.md`](GITHUB-CI.md) | What the GitHub workflows do, how to trigger them, and what GitHub can and cannot run |
| `sync-fork.ps1` | Fetch upstream → fast-forward `master` → merge into `maku-release` → push both |
| `identity.ps1` | Which account this clone commits and pushes as |

This page is the reference: what each thing is and why. The setup *order* lives
in `NEW-MACHINE.md` and is not repeated here.

## `sync-fork.ps1`

```powershell
.\contrib\fork\sync-fork.ps1
```

Run it from anywhere inside the repo. It adds the `upstream` remote if the clone
has none — and disables pushing to it in the same breath, because a remote added
without a push URL pushes to its *fetch* URL, which here is the upstream
repository itself.

### What it refuses to do

It stops rather than guessing:

- **Uncommitted changes to tracked files** — the branch switches would otherwise
  fail halfway and leave you on an unexpected branch. Untracked files are
  ignored: they do not block a checkout, and refusing over them would mean every
  machine had to exclude its own editor and tool config before the sync would
  run at all.
- **`master` has local commits** — it has stopped being a clean mirror, and the
  fast-forward every future sync depends on is already broken. Move them to a
  `feat/*` branch.
- **The identity check fails** — it pushes two branches; doing that as the wrong
  account is the whole thing the check exists to prevent. `-SkipIdentityCheck`
  overrides.
- **Upstream CI is not green on the target commit** — this fork disables
  upstream's ~50-job matrix rather than re-running it (a fork that adds
  `contrib/` cannot fix a failure in it, and inherits every upstream flake for
  nothing), so it reads upstream's own verdict via `gh api`.
  `-SkipUpstreamCiCheck` overrides.
- **A merge conflict** — the fork patches exactly one upstream-owned file, the
  fork guard in `.github/workflows/containers.yml`. A conflict anywhere else
  means something new is being carried, worth questioning before resolving.

Without `gh` the CI gate is skipped with a printed notice — a check that was
skipped should never look like one that passed. Upstream's tags are fetched but
never pushed; they would trigger this fork's tag-gated publishing workflows.

## `identity.ps1`

```powershell
.\contrib\fork\identity.ps1                    # check — the default
.\contrib\fork\identity.ps1 capture work       # save how this machine is now
.\contrib\fork\identity.ps1 define fork -From work
.\contrib\fork\identity.ps1 use fork
.\contrib\fork\identity.ps1 list
.\contrib\fork\identity.ps1 forget scratch
.\contrib\fork\identity.ps1 protect            # every git push checks first
.\contrib\fork\identity.ps1 unprotect
.\contrib\fork\identity.ps1 restore            # put this clone back as found
```

### Three things decide who you are, and `gh` owns one

| Mechanism | Set by | Owned by `gh`? |
| --- | --- | --- |
| Who authored the commit | `user.name` / `user.email` | **No** — gh stores no name or email |
| Who the push authenticates as | `credential.https://github.com.username` | **No** — the helper here is GCM |
| Who the CLI and API act as | gh's active account | **Yes** |

`gh` has no per-repository account — `gh auth switch` takes only `--hostname`
and `--user`, so it is one global value per host that another terminal can
change under you. (It is not limited to two accounts; `hosts.yml` stores an
arbitrary number.) That is why the first `use` snapshots it, `restore` puts it
back, and `check` verifies it every time rather than trusting it.

### It does not touch anything global

Only **repo-local** git config is written, so your global `user.name` /
`user.email` are never modified and every other repository on the machine is
unaffected. On a machine whose global identity is a work account, the fork
identity has to be a local override and the global one has to survive.

gh's active account is the single exception, being global by design. So the
first `use` snapshots the prior state:

| Snapshotted | What `restore` does |
| --- | --- |
| repo-local `user.name`, `user.email`, credential username | sets them back, **or unsets them again if they were unset** |
| gh's active account | switches it back |

The snapshot is taken **once** and never overwritten, so a second switch cannot
record the first switch's state as "original". Restoring an unset key as *unset*
rather than as an empty string is what keeps a machine genuinely untouched: a
clone that inherited its identity from global config goes back to inheriting it.

### No identifiers are in this repo

The fork is public. A name, email or username committed here is published
permanently — history, forks, mirrors, scrapers. So `identity.ps1` contains
none. Profiles live in `.git\fork-identity.json`, inside `.git`, which git
cannot track. `capture` fills that file from the machine itself, so nothing is
typed twice.

### What `check` refuses

| Refusal | Why it matters |
| --- | --- |
| Name, email or credential username is not the profile's | The commit would carry the wrong author, permanently and publicly |
| gh's active account is not the profile's | The commit is fine but gh commands are not — and this is the value that drifts |
| `origin` does not belong to the profile's account | Right identity, wrong destination |
| `upstream` can still be pushed to | A push could reach `dgtlmoon/changedetection.io` itself. An **unset** push URL counts: git falls back to the fetch URL |
| No profiles configured yet | It refuses rather than assuming the current identity is correct |

### Which path runs the check

| Situation | What runs it |
| --- | --- |
| `sync-fork.ps1` | Calls `identity.ps1 check` itself, before anything is pushed |
| Any `git push` | The pre-push hook, once `protect` has installed it |
| Anything else | `.\contrib\fork\identity.ps1` by hand |

The hook lives in `.git/hooks/`, which is per-clone and never committed — so it
is installed per machine and `git pull` will not bring it across. It exits 0 on
a branch that has no `contrib/fork/` (`master` is a mirror and has none);
blocking that push would break the sync it protects. `git push --no-verify`
bypasses it once.

## The branch model it assumes

| Branch | Role |
| --- | --- |
| `master` | The single pristine mirror of `upstream/master`, and the fork's **default branch**. Never commit to it |
| `maku-release` | The integration and release branch. All work lands here; CI builds it and deployments come from it |
| `feat/*` | Cut from `master`, merged into `maku-release` |

`master` is the default branch on purpose: GitHub's **Sync fork** button targets
the default branch, and because nothing but a fast-forward ever lands there, it
always succeeds.

`maku-release` is **merged into, never rebased**. Rebasing would flatten its
merge commits and rewrite every SHA, which means force-pushing the branch CI
builds and deployments pin. Rebase a `feat/*` branch instead, before merging it.

## About "N commits ahead, M commits behind"

On `maku-release`, GitHub's branch page shows something like *"51 commits ahead
of, 0 commits behind dgtlmoon/changedetection.io:master"*. Only one of those
numbers is actionable:

| Number | Meaning | Should it be zero? |
| --- | --- | --- |
| **behind** | Upstream has commits this branch has not taken | **Yes** — that is `sync-fork.ps1`'s job |
| **ahead** | This branch has commits upstream does not | **No** — that is the fork's own work |

A fork that carries changes is ahead by definition; the only way to show
`0 ahead` is to carry nothing. "Behind" is real drift and compounds — the longer
it runs, the likelier the eventual conflicts.

`master` shows `0 ahead, 0 behind` after a sync, being a mirror.

## Not to be confused with

[`contrib/podman/update.ps1`](../podman/update.ps1) pulls the branch you already
have checked out and restarts the app. It never merges, switches branch or
pushes. That one is for a machine that only runs the app; `sync-fork.ps1` is for
the machine where the work happens.
