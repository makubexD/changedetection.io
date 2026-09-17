# The branch model, and keeping up with upstream

How this fork is arranged, why, and what `fork sync` does about it.

Who this clone commits as is a different subject: [`IDENTITY.md`](IDENTITY.md).

## The branches

| Branch | Role |
| --- | --- |
| `master` | The single pristine mirror of `upstream/master`, and the fork's **default branch**. Never commit to it |
| `maku-release` | The integration and release branch. All work lands here; CI builds it and deployments come from it |
| `feat/*` | Cut from `master`, merged into `maku-release` |

`master` is the default branch on purpose: GitHub's **Sync fork** button targets
the default branch, and because nothing but a fast-forward ever lands there, it
always succeeds.

`maku-release` is **merged into, never rebased**. Rebasing would flatten its
merge commits and rewrite every SHA, which means force-pushing the branch that
CI builds and deployments pin. Rebase a `feat/*` branch instead, before merging
it.

`contrib/` and the fork's workflows live on `maku-release` **only**. They name
this fork's branches, its upstream and its image, so they are kept off `master`
and off the `feat/*` branches, which stay proposable upstream unchanged.

## `fork sync`

```powershell
.\contrib\maku.ps1 fork sync
```

In order: fetch `upstream/*` → fast-forward `master` → push it → merge `master`
into `maku-release` → push that. Run it from anywhere inside the repo.

It adds the `upstream` remote if the clone has none — and disables pushing to it
in the same breath, because a remote added without a push URL pushes to its
*fetch* URL, which here is the upstream repository itself.

### What it refuses to do

It stops rather than guessing:

- **Uncommitted changes to tracked files** — the branch switches would otherwise
  fail halfway and leave you on an unexpected branch. Untracked files are
  ignored: they do not block a checkout, and refusing over them would mean every
  machine had to exclude its own editor config before the sync would run at all.
- **`master` has local commits** — it has stopped being a clean mirror, and the
  fast-forward every future sync depends on is already broken. Move them to a
  `feat/*` branch.
- **The identity check fails** — it pushes two branches, and doing that as the
  wrong account is the whole thing the check exists to prevent.
  `-SkipIdentityCheck` overrides.
- **Upstream CI is not green on the target commit** — this fork disables
  upstream's ~50-job matrix rather than re-running it (a fork that adds
  `contrib/` cannot fix a failure in it, and would inherit every upstream flake
  for nothing), so it reads upstream's own verdict via `gh api`.
  `-SkipUpstreamCiCheck` overrides.
- **A merge conflict** — this fork patches exactly one upstream-owned file, the
  fork guard in `.github/workflows/containers.yml`. A conflict anywhere else
  means something new is being carried, which is worth questioning before
  resolving.

Without `gh` the CI gate is skipped with a printed warning — a check that was
skipped must never look like one that passed. Upstream's tags are fetched but
never pushed; they would trigger this fork's tag-gated publishing workflows.

### The ordering that matters

`fork sync` repairs the `upstream` push URL **before** running the identity
check, because that check refuses while upstream is pushable — which on a fresh
clone is exactly the state the repair fixes. Run the other way round, the guard
would block the only thing able to satisfy it.

## About "N commits ahead, M commits behind"

```powershell
.\contrib\maku.ps1 fork status
```

On `maku-release`, GitHub's branch page shows something like *"64 commits ahead
of, 0 commits behind dgtlmoon/changedetection.io:master"*. Only one of those
numbers is actionable:

| Number | Meaning | Should it be zero? |
| --- | --- | --- |
| **behind** | Upstream has commits this branch has not taken | **Yes** — that is `fork sync`'s job |
| **ahead** | This branch has commits upstream does not | **No** — that is the fork's own work |

A fork that carries changes is ahead by definition; the only way to show
`0 ahead` is to carry nothing. "Behind" is real drift and compounds — the longer
it runs, the likelier the eventual conflicts.

`master` shows `0 ahead, 0 behind` after a sync, being a mirror.

## Not to be confused with

[`app update`](../podman/DEPLOY.md#updating-to-the-latest-code) pulls the branch
you already have checked out and restarts the app. It never merges, switches
branch or pushes. That one is for a machine that only runs the app; `fork sync`
is for the machine where the work happens.
