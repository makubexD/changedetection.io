# Identity: who this clone commits and pushes as

The reference. Every command, every refusal, every file it writes, and the
situation you are probably in.

Why it is built this way: [`ADR-IDENTITY.md`](ADR-IDENTITY.md).
Setting up a machine in order: [`SETUP.md`](SETUP.md).

## Three things decide who you are, and they fail differently

| Mechanism | Set by | Decides |
| --- | --- | --- |
| Commit author | `user.name` / `user.email` | who wrote the commit — **public and permanent** |
| Push credential | `credential.https://github.com.username` → GCM | which account GitHub records as the pusher |
| CLI account | gh's active account | who `gh pr create` and `gh api` act as |

They are independent. Getting the second wrong means a push fails; getting the
**first** wrong means a public repository carries the wrong name forever. That
is the one the guard is really for.

> **`gh auth switch` does not affect git.** It rewrites one line in gh's own
> `hosts.yml` and nothing else. If a `git pull` ever starts asking for a
> password, gh has been made the credential helper again — run
> `.\contrib\maku.ps1 auth show`.

## What is written where

Nothing personal is in the repository. All of it is in `.git/`, which git cannot
track, or in the OS credential store.

| Location | Holds | Survives a re-clone? |
| --- | --- | --- |
| repo-local `.git/config` | `user.name`, `user.email`, the pinned account, `user.useConfigOnly` — **the whole identity** | No |
| `.git/hooks/pre-push` | the guard | No |
| `.git/fork-guard/` | what the guard runs, so every branch is covered | No |
| Windows Credential Manager | one token per account, `git:https://<user>@github.com` | Yes |
| global `.gitconfig` | `credential.helper = manager`, and the machine's default account | Yes |
| gh's `hosts.yml` | the accounts, and the active one — **CLI only** | Yes |

That is why setup is per clone, and why a second machine repeats it.

## The commands

```powershell
.\contrib\maku.ps1 identity init <account>   # once per clone
.\contrib\maku.ps1 identity show             # is this clone set up correctly?
.\contrib\maku.ps1 identity reset            # unset the local keys again

.\contrib\maku.ps1 guard enable              # check every push before it leaves
.\contrib\maku.ps1 guard check               # would a push be allowed right now?
.\contrib\maku.ps1 guard disable

.\contrib\maku.ps1 auth show                 # what supplies credentials, machine-wide
.\contrib\maku.ps1 auth repair               # stop gh being the helper
```

### `identity init <account>`

Writes three repo-local keys and `user.useConfigOnly`. It asks for the name and
address once, pre-filled from what the clone already has, then from the GitHub
profile; pass `-Name` and `-Email` to skip the questions. Run it again only to
correct a value.

### `identity show`

Reports and changes nothing:

```
  commits as   makubexD <…@…>
  push as      makubexD
  origin       makubexD
  helper       manager
  gh active    makubexD
  push guard   on

OK    identity   this clone is pinned, and the credential mechanism honours it
```

Exits non-zero on anything it refuses, so it can gate other commands — which is
how `fork sync` uses it.

### `guard check`

What the hook runs. By hand it checks configuration, the destination and the
environment; from the hook it also reads the pushed ref range on stdin and
inspects **the authorship of the commits about to be published**. That is the
check that matters: configuration being right now says nothing about a commit
made last week.

## What it refuses, and why

| Refusal | Why it matters |
| --- | --- |
| This clone sets no local identity | It would inherit the machine's — on a work machine, that is the work account, in a public repo, permanently |
| No account pinned | Pushes fall back to the machine default |
| Commits in the range are not authored by this clone's address | The irreversible one. It names the commits |
| The push goes to an account this clone is not pinned to | Right identity, wrong destination |
| A remote points at someone else's repository and its push URL is not `DISABLED` | An **unset** push URL counts: git falls back to the fetch URL |
| `GH_TOKEN` / `GITHUB_TOKEN` is set | Makes gh's helper skip its own username check entirely |
| `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` is set | Overrides the config just validated |
| gh is the credential helper | Only its active account can authenticate; everything else is prompted. A **failure** here, but only a **warning** in the push guard — it cannot forge a commit, it just breaks authentication. [Why the two differ](ADR-IDENTITY.md#7-what-refuses-and-what-only-warns) |
| The guard is **stale** | The installed hook points at tooling that no longer exists, or a file it needs under `.git/fork-guard` is missing — either way it cannot run its check, and a hook that cannot run its check is not a check |

Warnings, not refusals: gh being active as another account (it affects
`gh pr create`, not the push), gh being **unreachable** so that which account it
would act as cannot be determined — reported explicitly rather than skipped,
because a check that was not made must never look like one that passed —
leftover `.git/fork-identity*.json` from the old
profile store, and the guard being **drifted** — its copies are an older
revision of the tooling, so the check still runs and commits are still verified,
just not by the newest logic. A refusal there would fire on every edit to
`contrib/lib` during ordinary work, and one that fires constantly is one people
learn to ignore.

## Which path runs the check

| Situation | What runs it |
| --- | --- |
| `fork sync` | calls `identity show` itself, before anything is pushed |
| Any `git push` | the pre-push hook, once `guard enable` has installed it |
| Anything else | `.\contrib\maku.ps1 identity show` by hand |

`fork sync` repairs the `upstream` push URL **before** checking, because the
check refuses while upstream is pushable — which on a fresh clone is the state
that function exists to fix.

`git push --no-verify` bypasses the hook once.

## The situation you are in

| Situation | What to do |
| --- | --- |
| Setting up any clone, any account | `identity init <account>`, then `guard enable` |
| Adding a third account | Same. GCM signs in once on the first push, then never again |
| Switching which account you **push** as | You do not. Each clone is pinned; there is nothing to switch |
| Switching which account **gh** acts as | `gh auth switch -u <name>` — affects `gh pr create` and `gh api` only |
| A password prompt where there should not be one | `gh auth login` re-added the gh helper. `auth show`, then `auth repair` |
| The first push from a new account | One GCM sign-in. Verify which account was stored: `.\contrib\maku.ps1 auth show` |
| Second machine, or a re-clone | `identity init` again — `.git/config` does not travel |
| Handing the machine back | `identity reset`, then `guard disable`. Global config was never modified |
| On `master` | A mirror; its pushes are upstream commits. The guard passes them deliberately |
| On a `feat/*` branch | Guarded, like every other branch |
| A wrong-author commit is already local | The guard blocks the push and names the commits. Rewriting them is yours to do |
| `gh` is not installed | Git works fully — GCM does not need it. `gh pr create` and the upstream-CI gate in `fork sync` do |

## When something will not pass

| Symptom | Cause |
| --- | --- |
| `Authentication failed` on a repo that used to work | gh is the credential helper again → `auth repair` |
| The guard never fires | Per clone: run `guard enable` on **this** machine. Also check for `--no-verify` |
| `git push` fails on credentials, not on the hook | git contacts the remote before the hook runs, so authentication fails first. That is a credential problem, not a guard problem |
| `identity show` says the guard is **stale** | The hook predates this tooling, or a file under `.git/fork-guard` is missing → `guard enable` |
| `identity show` says the guard is **drifted** | You edited or pulled `contrib/lib`; the guard's copies are the previous revision → `guard enable` |
| `guard enable` refuses | A `pre-push` hook this tool did not write is already there; it is left alone deliberately |
| `identity init` says it needs an interactive console | Pass `-Name` and `-Email` directly |
| `origin belongs to X but this clone pushes as Y` | Either the wrong clone or the wrong pin. `identity init <owner-of-origin>` |
