# Fork maintenance

Tooling for keeping this fork in step with `dgtlmoon/changedetection.io`.

**This directory exists only on `maku-release`.** It is fork-specific by nature —
it names this fork's branches and its upstream — so it is deliberately kept off
`master` (a pristine mirror) and off the `feat/*` branches, which are written to
be proposable upstream unchanged.

| File | What it does |
| --- | --- |
| `sync-fork.ps1` | Fetch upstream → fast-forward `master` → merge `master` into `maku-release` → push both |

```powershell
.\contrib\fork\sync-fork.ps1
```

Run it from anywhere inside the repo. It adds the `upstream` remote if the clone
does not have one, so a fresh `git clone` of the fork works with no setup.

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
