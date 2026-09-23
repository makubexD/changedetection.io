#: bring upstream's commits into master, then into the release branch

<#
.SYNOPSIS
    Fetch upstream, fast-forward master, merge it into the release branch, push both.

.DESCRIPTION
    In order:
        1. upstream/master and tags fetched (the remote is added, fetch-only, if absent)
        2. master          fast-forwarded to upstream/master, then pushed
        3. release branch  master merged in, then pushed

    WHY MASTER IS NEVER COMMITTED TO. It is a pristine mirror and the fork's
    default branch, which makes two things work: GitHub's "Sync fork" button
    always succeeds, and step 2 is always a fast-forward. One local commit on
    master and every future sync needs conflict resolution instead.

    WHY THE RELEASE BRANCH IS MERGED, NOT REBASED. It is what CI builds and what
    deployments pin. Rebasing rewrites every SHA and forces a push to that branch;
    merging keeps it append-only. Rebase feat/* branches instead, before merging.

    Upstream tags are fetched but never pushed -- they would trigger this fork's
    tag-gated publishing workflows.

.PARAMETER ReleaseBranch
    The integration branch upstream is merged into.

.PARAMETER SkipUpstreamCiCheck
    Sync even when upstream's own CI is red or still running. Use knowingly.

.PARAMETER SkipIdentityCheck
    Push without verifying which account this clone is. Only for a clone you have
    already checked by hand.

.EXAMPLE
    .\contrib\maku.ps1 fork sync
#>
param(
    [string]$ReleaseBranch = 'maku-release',
    [switch]$SkipUpstreamCiCheck,
    [switch]$SkipIdentityCheck
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1')    -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

$upstreamUrl = 'https://github.com/dgtlmoon/changedetection.io.git'
$repoRoot    = Get-RepoRoot

function Invoke-Checkout([string]$branch) {
    & git checkout $branch
    if ($LASTEXITCODE -ne 0) { throw "could not check out '$branch'" }
}

# A fresh clone has no 'upstream'. Add it rather than failing with an error the
# reader then has to translate into this command themselves -- and disable
# pushing to it in the same breath, because a remote added without a push URL
# pushes to its FETCH url, which here is the upstream repository itself.
function Assert-UpstreamRemote {
    & git remote get-url upstream 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Adding 'upstream' -> $upstreamUrl"
        & git remote add upstream $upstreamUrl
        if ($LASTEXITCODE -ne 0) { throw 'could not add the upstream remote' }
    }
    $pushUrl = & git config --get remote.upstream.pushurl
    if ($LASTEXITCODE -ne 0 -or -not $pushUrl) {
        Write-Host "Disabling pushes to 'upstream' (it is fetch-only by design)."
        & git remote set-url --push upstream DISABLED
        if ($LASTEXITCODE -ne 0) { throw 'could not disable the upstream push URL' }
    }
}

# Upstream already ran its ~50-job matrix on this exact SHA. Reading that verdict
# is a better answer than a second run would be -- which is why this fork disables
# those workflows rather than re-running them.
#
# --paginate IS NOT OPTIONAL. The endpoint returns 30 check runs per page and
# upstream currently produces well over a hundred, so without it this gate reads a
# third of the matrix and calls the whole thing green: a failure on page two would
# sync silently. The count printed on success is the proof it read them all.
function Assert-UpstreamCiGreen([string]$sha) {
    $short = $sha.Substring(0, 8)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn 'ci' "gh is not installed -- upstream CI was NOT checked for $short."
        return
    }
    $runs = gh api --paginate "repos/dgtlmoon/changedetection.io/commits/$sha/check-runs" `
                --jq '.check_runs[] | "\(.conclusion)"' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "could not read upstream check runs for $sha" }

    $all = @($runs | Where-Object { $_ })
    # 'skipped' and 'neutral' are normal outcomes for path-filtered jobs.
    $bad     = @($all | Where-Object { $_ -notin 'success', 'skipped', 'neutral' })
    $pending = @($all | Where-Object { $_ -eq '' -or $_ -eq 'null' })

    if ($all.Count -eq 0) {
        throw "Upstream has no CI results for $short yet. Wait, or pass -SkipUpstreamCiCheck."
    }
    if ($bad.Count -gt 0 -or $pending.Count -gt 0) {
        throw ("Upstream CI is not green for ${short}: $($bad.Count) failing, " +
               "$($pending.Count) still running, $($all.Count) total. " +
               "Override with -SkipUpstreamCiCheck.")
    }
    Write-Pass 'ci' "upstream green for $short ($($all.Count) checks)"
}

Push-Location $repoRoot
try {
    # Remote safety FIRST, then the identity check. The check refuses while
    # upstream can still be pushed to, which on a fresh clone is the state this
    # very function fixes -- run the other way round, the guard would block the
    # only thing able to satisfy it.
    Assert-UpstreamRemote

    # The identity check now lives in `gid`, which is installed per machine
    # rather than carried in this repository -- see contrib/fork/SETUP.md. It is
    # an OPTIONAL dependency here: a sync is refused when gid says the identity
    # is wrong, but never merely because gid is absent. A missing optional tool
    # must not block a sync, and the pre-push hook still refuses on its own if
    # anything actually tries to leave with the wrong identity.
    if ($SkipIdentityCheck) {
        Write-Warn 'identity' "check SKIPPED by request -- pushing as $(& git config user.name)."
    } elseif (Get-Command gid -ErrorAction SilentlyContinue) {
        & gid
        if ($LASTEXITCODE -ne 0) {
            throw 'Identity check failed (above). Fix it, or re-run with -SkipIdentityCheck.'
        }
    } else {
        Write-Warn 'identity' 'gid is not installed, so the identity was NOT verified here.'
        Write-Host "         install it, then re-run:  npm install -g gid"
    }
    Assert-CleanTree

    # Only master, because it is the only upstream branch this sync reads.
    # Fetching every branch breaks on Windows whenever upstream has two names
    # that differ only by case (it has both `llm` and `LLM/...`): Git can't
    # store both refs on a case-insensitive filesystem.
    & git fetch upstream --tags --prune '+refs/heads/master:refs/remotes/upstream/master'
    if ($LASTEXITCODE -ne 0) { throw 'git fetch upstream failed' }

    # Checked before master is touched, so the error names the real problem
    # instead of surfacing later as a merge failure.
    $ahead = (& git rev-list --count upstream/master..master).Trim()
    if ($ahead -ne '0') {
        throw ("master has $ahead local commit(s) -- it is no longer a clean mirror. " +
               "Move them to a feat/* branch and reset master to upstream/master.")
    }

    $target = (& git rev-parse upstream/master).Trim()
    if ($SkipUpstreamCiCheck) {
        Write-Warn 'ci' "check SKIPPED by request for $($target.Substring(0,8))."
    } else {
        Assert-UpstreamCiGreen $target
    }

    Invoke-Checkout master
    & git merge --ff-only upstream/master
    if ($LASTEXITCODE -ne 0) { throw 'master could not fast-forward to upstream/master' }
    & git push origin master
    if ($LASTEXITCODE -ne 0) { throw 'could not push master' }

    Invoke-Checkout $ReleaseBranch
    $behind = (& git rev-list --count "$ReleaseBranch..master").Trim()
    if ($behind -eq '0') {
        Write-Host "$ReleaseBranch already contains everything in master -- nothing to merge."
    } else {
        Write-Host "Merging $behind new upstream commit(s) into $ReleaseBranch..."
        & git merge --no-edit master
        if ($LASTEXITCODE -ne 0) {
            throw ("Merge conflict. This fork patches exactly one upstream-owned file -- the " +
                   "fork guard in .github/workflows/containers.yml. A conflict anywhere else " +
                   "means something new is being carried, and is worth questioning before " +
                   "resolving. Fix it, then: git commit && git push origin $ReleaseBranch")
        }
        & git push origin $ReleaseBranch
        if ($LASTEXITCODE -ne 0) { throw "could not push $ReleaseBranch" }
    }

    & (Join-Path $PSScriptRoot 'status.ps1') -Branch $ReleaseBranch
    Write-Pass 'sync' 'complete'
}
finally { Pop-Location }
