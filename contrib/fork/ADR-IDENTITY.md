# Decisions: how this clone authenticates and who it commits as

Why the identity tooling is shaped the way it is. Each section states the
problem, what was rejected, and what it costs — so the reasoning survives the
next person who wonders why, including you in six months.

Reference for *using* it: [`IDENTITY.md`](IDENTITY.md).

---

## 1. Git credentials come from GCM. `gh` is for the CLI and the API.

### The requirement

Authenticate once per account, then every repository works from anywhere with no
prompt — including after switching which account you are acting as.

### What was there before

`gh auth setup-git` had written this into global `.gitconfig`:

```ini
[credential "https://github.com"]
    helper =                                      # empty
    helper = !'…\gh.exe' auth git-credential
```

`gitcredentials(7)` defines an empty `helper` as *reset the list*, so the
inherited `credential.helper = manager` was discarded and **gh became the only
credential helper for github.com**. Git Credential Manager never ran for GitHub
at all.

### Why gh cannot meet the requirement

In `cli/cli`, `pkg/cmd/auth/gitcredential/helper.go` resolves the token with
`ActiveToken(host)` — **by host, never by the requested username**. The username
git sends is only a rejection filter: asked for an account that is not active,
gh returns nothing and exits 1, even though that account's token is sitting in
the same keyring.

Verified on this machine, tokens never printed:

| git asks gh for | gh returns |
| --- | --- |
| the non-active account | **nothing**, exit 1 |
| the active account | that account |
| *(no username)* | the active account |

So every `gh auth switch` guarantees a password prompt on the other side. It
reproduces exactly as:

```
gh auth switch                 -> the other account
git pull origin                # in a repo pinned to the first
    remote: Invalid username or token. Password authentication is not supported
    fatal: Authentication failed
```

This is structural, not configuration. `gh auth switch` takes only `--hostname`
and `--user`; there is no repo-local gh account. cli/cli **#8875** is open, and
PR **#13468**, which would have added `--account` to the credential helper, was
**closed unmerged** — a maintainer noting the approach was not agreed.

### Why GCM does

GCM stores one credential per account, keyed `git:https://<user>@github.com`,
and selects per repository from `credential.<url>.username`. That is its
documented multi-account feature, and it is exactly "authenticate once, then it
works from anywhere". It was already installed and already held the work
account, so the migration cost one sign-in.

### The decision

Remove the two entries `gh auth setup-git` added, and nothing else.
`credential.helper = manager` is already underneath them, so github.com returns
to GCM. `auth repair` does this and `auth show` reports it.

**gh keeps the job it is good at**: the account store, `gh auth login`,
`gh pr create`, `gh api`, and the upstream-CI gate in `fork sync`. It simply
stops being in the path of `git push` and `git pull`.

### What was rejected

| Option | Why not |
| --- | --- |
| **Keep gh as the helper** | Cannot satisfy the requirement, as above. It also inverts the safety property: the tool would have to mutate machine-global gh state to make one repository work. |
| **SSH with repo-local `core.sshCommand`** | Genuinely stronger — GitHub binds a public key to exactly one account, so the choice is enforced server-side and no `gh auth switch` can affect it. Rejected because it adds key management to a machine that uses no SSH at all, for a requirement GCM already meets. Reconsider this if per-repo isolation ever needs to be cryptographic rather than configured. |
| **A PAT in the remote URL** | Writes a live credential into `.git/config`, where it reaches every backup, every `git remote -v` pasted into an issue, and cannot be rotated by the OS credential store. |
| **A wrapper that saves and restores state around `gh auth switch`** | There is nothing to save. The other account's token is in the keyring the whole time; gh declines to serve it. Automating switch → act → switch back still fails for anything done while switched. |
| **`GH_CONFIG_DIR` per repository** | Would give a per-shell account store, but fragments the store — the opposite of keeping every account in one place. |

### What it costs

- One interactive GCM sign-in per account, once. Because the browser may be
  signed in as someone else, verifying which account was stored is part of the
  procedure, not an optional extra: `.\contrib\maku.ps1 auth show`.

  Use that rather than `git-credential-manager` directly. On Windows GCM ships
  inside Git's own directory (`…\Git\mingw64\bin`), which Git Bash puts on PATH
  and PowerShell does not — so the bare command reports "not found" on a machine
  where GCM is installed and holding credentials. `auth show` resolves it by
  location instead.
- `gh auth login` may offer to configure git credentials again, which re-adds
  the two entries. Decline it. `auth show` and `identity show` both detect the
  regression and name the fix.
- Reversible in one command: `gh auth setup-git`.

---

## 2. The guard verifies commits, not just configuration

A wrong-account **push** to a fork you do not own fails at GitHub — the account
is not a collaborator, so it is a 403. It is recoverable.

A wrong-author **commit** is not. `user.email` is baked into the author and
committer fields; once pushed to a public repository it is in history, forks,
mirrors and scrapers permanently, and if that address is verified on the other
account, GitHub attributes the commit to it.

The previous hook read the pushed ref range on stdin and **discarded it**, so it
asked "is the config right at this instant" — a proxy. A commit authored before
setup, or on a branch where the identity was never applied, passed cleanly once
the config was corrected afterwards.

So the guard reads its stdin and inspects the authorship of every commit in the
range being published. That covers commits made before setup, after
`identity reset`, on any branch, and those introduced by merge, rebase,
cherry-pick or an IDE — none of which a config check can see.

It also refuses when `GH_TOKEN` or `GITHUB_TOKEN` is set, because those make gh's
helper skip its own username check entirely, and when `GIT_AUTHOR_EMAIL` or
`GIT_COMMITTER_EMAIL` is set, because each silently overrides the config just
validated.

---

## 3. The guard runs from `.git/`, not from the working tree

The old hook looked for its checker at `contrib/fork/identity.ps1` **in the
checkout**, and exited 0 when it was absent.

`contrib/` exists only on the release branch. That exemption was written for
`master` — a pristine mirror whose pushes are upstream commits nobody here
authored — but it silently covered every `feat/*` branch too. Five of six
branches, including every branch that carried work, pushed unguarded.

`guard enable` therefore copies what the check needs into `.git/fork-guard/`,
which is per-clone, never committed, and identical on every branch. The only
fail-open left is scoped to the ref actually being pushed (`refs/heads/master`),
not to whatever happens to be checked out.

A hook that cannot find its checker now **refuses** rather than passing in
silence — a check that did not run must never read as a check that passed.

---

## 4. There is no profile store

There used to be `.git/fork-identity.json`, a snapshot file, and
`capture` / `define` / `use` / `list` / `forget` / `restore` around them, to
switch identity inside one clone.

Nothing needs that. **A clone belongs to one account, permanently** — this fork
is always its owner's, a work checkout is always the work account's. What you
switch is gh's active account, which is a machine-wide mode and gh's own
business. The store was solving a problem that does not arise, and reimplemented
a per-clone config store that git already provides.

Identity is now three repo-local git config keys, set once by `identity init`.
`.git/config` is exactly as un-committable as the JSON file was, with none of the
bespoke code: 438 lines became about 120, nine commands became three, and two
files in `.git/` became none.

---

## 5. No names or addresses live in the repository

The fork is public. Anything committed here is published permanently. So the
tooling contains no identifiers: everything personal lives in `.git/config`,
which git cannot track, and `identity init` asks for it once per clone.

That is also why setup is per machine and why a re-clone repeats it. It is a
deliberate cost, not an oversight.

---

## 6. Deliberately not done

| Not done | What it would fix | Why not |
| --- | --- | --- |
| **`includeIf "gitdir:…"` in global config** | The fresh-clone window: between `git clone` and `identity init`, a commit inherits the machine's global identity. | It writes new identity behaviour into global config. The migration in §1 only *removes* entries; this would add. The guard catches such commits at push time instead. |
| **A GitHub ruleset restricting author and committer emails** | The only control `git push --no-verify` cannot bypass, since GitHub enforces it on receive. | A settings change on the repository rather than on this machine. Worth doing if `--no-verify` ever becomes a habit. |
| **A `pre-commit` hook** | Would catch a wrong-author commit at the moment it is made. | Skipped by `commit --no-verify`, and by merge, rebase, cherry-pick and revert — so it would give partial cover for a risk the range check already covers completely. |

## 7. What refuses, and what only warns

A condition can be reported at two different severities by two different
commands without either being wrong, because they answer different questions.
The rule is **what is irreversible**:

| | Refuses | Warns |
| --- | --- | --- |
| **Question** | Would this publish something that cannot be taken back? | Is something here not as it should be? |
| **Asked by** | the pre-push guard | `identity show`, `auth show` |

A **commit** is irreversible once pushed to a public fork — its author and
committer addresses are in the object graph permanently. That is what the guard
refuses over, and nothing else.

A **credential** problem is not. A wrong helper, or gh being active as another
account, makes a push fail to authenticate — loudly, immediately, and with
nothing published. Blocking the push adds nothing the failure would not already
tell you, and would refuse pushes that are in fact perfectly safe.

So the two commands differ on purpose:

| Condition | `guard check` | `identity show` | Why |
| --- | --- | --- | --- |
| A commit in the pushed range has a foreign author | **refuse** | not its job | Irreversible once published |
| No identity pinned in this clone | **refuse** | **fail** | The next commit would inherit the machine's identity |
| `GH_TOKEN` / `GIT_AUTHOR_EMAIL` set | **refuse** | — | Silently outranks the config just validated |
| Push destination is not this account's | **refuse** | **fail** | Wrong repository entirely |
| gh is the git credential helper | **warn** | **fail** | Cannot forge a commit; it only breaks authentication — but the clone is misconfigured |
| gh active as another account | **warn** | **warn** | Affects `gh pr create`, never the push |
| gh could not be queried | **warn** | **warn** | Unknown, and said so rather than skipped |
| Guard copies are `drifted` | — | **warn** | The check still runs, just an older revision |
| Guard is `stale` | — | **fail** | The check cannot run at all |

The one rule this encodes: **a check that was skipped must never look like one
that passed.** Every "unknown" above is printed, never omitted. The guard also
says in its own output why it is warning rather than refusing, so the two
commands do not look like they disagree.

## Residual risks, stated plainly

- `git push --no-verify` skips the guard, as does any tool pushing through
  libgit2 rather than the `git` binary. Hooks are advisory by design.
- Environment variables outrank config. The guard refuses when it can see them
  set, which is a check, not a guarantee.
- A fresh clone has no hook until `guard enable` runs.
- `gh pr create` and `gh api` act as gh's active account, and no git config
  affects them. `identity show` warns when it differs; nothing can enforce it.
- Commits already made with the wrong author must be rewritten by hand. The
  guard blocks the push and names them; it does not rewrite history.
