# Sync this fork with dgtlmoon/changedetection.io, then bring master's new
# commits into the release branch.
#
#   .\contrib\fork\sync-fork.ps1
#
# What it does, in order:
#   1. upstream/*      fetched (the remote is added if this clone lacks it)
#   2. master          fast-forwarded to upstream/master, then pushed
#   3. maku-release    master merged in, then pushed
#
# WHY MASTER IS NEVER COMMITTED TO. It is a pristine mirror and the fork's
# default branch, which is what makes two things work: GitHub's "Sync fork"
# button always succeeds, and step 2 is always a fast-forward. One local commit
# on master and every future sync needs conflict resolution instead.
#
# WHY THE RELEASE BRANCH IS MERGED, NOT REBASED. maku-release is what CI builds
# and deploys from. Rebasing rewrites every SHA and forces a push to that
# branch; merging keeps it append-only. Rebase feat/* branches instead, before
# they are merged.
#
# ABOUT THE GITHUB BANNER. On maku-release GitHub shows "N commits ahead of, M
# commits behind dgtlmoon/changedetection.io:master". This script drives M to 0
# and keeps it there. It cannot drive N to 0 -- those N commits are the fork's
# own work, and a branch that carries work is ahead by definition. N is not a
# problem to fix; M is.
param(
    [string]$ReleaseBranch = 'maku-release',
    # Sync even when upstream's own CI is red or still running. Use knowingly.
    [switch]$SkipUpstreamCiCheck,
    # Push without checking which account you are. Only for a clone that has
    # no profiles configured yet and that you have verified by hand.
    [switch]$SkipIdentityCheck
)
$ErrorActionPreference = 'Stop'

# git answers questions through exit codes rather than only reporting failure
# with them, and PowerShell 7.4+ turns any non-zero code into a terminating
# error. Exit codes are checked by hand below, everywhere it matters.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot   = Resolve-Path "$PSScriptRoot\..\.."
$upstreamUrl = 'https://github.com/dgtlmoon/changedetection.io.git'

function Assert-CleanTree {
    $dirty = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "not a git repository: $repoRoot" }
    if ($dirty) {
        throw "Working tree is not clean -- commit or stash first:`n$dirty"
    }
}

# A fresh clone of the fork has no 'upstream'. Add it rather than failing with
# an error the reader then has to translate into this command themselves.
function Assert-UpstreamRemote {
    $null = & git remote get-url upstream 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Adding 'upstream' remote -> $upstreamUrl"
        & git remote add upstream $upstreamUrl
        if ($LASTEXITCODE -ne 0) { throw "could not add the upstream remote" }
    }
}

# The guard is a sibling in this directory, so it is present on every clone
# that has this script -- which is the point of both living in the repo. It
# throws on a mismatch and that is intended to stop the sync: this function
# pushes two branches, and doing so as the wrong account is the exact mistake
# the guard exists to prevent.
function Invoke-IdentityGuard {
    $guard = Join-Path $PSScriptRoot 'identity.ps1'
    if (-not (Test-Path $guard)) {
        throw "identity.ps1 is missing from $PSScriptRoot -- refusing to push " +
              "without an identity check. Restore it, or re-run with -SkipIdentityCheck."
    }
    & $guard -Action check
}

# Upstream already ran its ~50-job matrix on this exact SHA. Reading that
# verdict is one API call and a better answer than a second run would be --
# which is why this fork disables those workflows rather than re-running them.
function Assert-UpstreamCiGreen([string]$sha) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "NOTE: gh not installed -- upstream CI NOT checked for $($sha.Substring(0,8))."
        return
    }
    $runs = gh api "repos/dgtlmoon/changedetection.io/commits/$sha/check-runs" `
                --jq '.check_runs[] | "\(.conclusion)"' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "could not read upstream check runs for $sha" }

    $all = @($runs | Where-Object { $_ })
    # "skipped" and "neutral" are normal outcomes for path-filtered jobs.
    $bad     = @($all | Where-Object { $_ -notin 'success', 'skipped', 'neutral' })
    $pending = @($all | Where-Object { $_ -eq '' -or $_ -eq 'null' })

    if ($all.Count -eq 0) {
        throw "Upstream has no CI results for $($sha.Substring(0,8)) yet. " +
              "Wait, or re-run with -SkipUpstreamCiCheck."
    }
    if ($bad.Count -gt 0 -or $pending.Count -gt 0) {
        throw "Upstream CI is not green for $($sha.Substring(0,8)): $($bad.Count) failing, " +
              "$($pending.Count) still running, $($all.Count) total. " +
              "Re-run with -SkipUpstreamCiCheck to override."
    }
    "Upstream CI green for $($sha.Substring(0,8)): $($all.Count) checks."
}

# The two numbers GitHub prints on the branch page, so the banner can be read
# from here without opening a browser.
function Show-BannerState([string]$branch) {
    $ahead  = & git rev-list --count "upstream/master..$branch"
    $behind = & git rev-list --count "$branch..upstream/master"
    Write-Host ""
    Write-Host "GitHub will show for ${branch}:"
    Write-Host "    $ahead commits ahead of, $behind commits behind dgtlmoon/changedetection.io:master"
    if ($behind -eq '0') {
        Write-Host "    'behind' is 0 -- that is the half this script controls."
        Write-Host "    'ahead' is this fork's own work and is supposed to be there."
    }
}

Push-Location $repoRoot
try {
    if ($SkipIdentityCheck) {
        Write-Host "Identity check SKIPPED by request -- pushing as $(& git config user.name)."
    } else {
        Invoke-IdentityGuard
    }
    Assert-CleanTree
    Assert-UpstreamRemote

    & git fetch upstream --tags --prune
    if ($LASTEXITCODE -ne 0) { throw "git fetch upstream failed" }

    # Checked before master is touched, so the error names the real problem
    # instead of surfacing later as a merge failure.
    $ahead = & git rev-list --count upstream/master..master
    if ($ahead -ne '0') {
        throw "master has $ahead local commit(s) -- it is no longer a clean mirror. " +
              "Move them to a feat/* branch and reset master to upstream/master."
    }

    $target = & git rev-parse upstream/master
    if ($LASTEXITCODE -ne 0) { throw "could not resolve upstream/master" }

    if ($SkipUpstreamCiCheck) {
        "Upstream CI check SKIPPED by request for $($target.Substring(0,8))."
    } else {
        Assert-UpstreamCiGreen $target
    }

    & git checkout master
    & git merge --ff-only upstream/master
    if ($LASTEXITCODE -ne 0) { throw "master could not fast-forward to upstream/master" }
    & git push origin master
    if ($LASTEXITCODE -ne 0) { throw "could not push master" }

    & git checkout $ReleaseBranch
    if ($LASTEXITCODE -ne 0) { throw "no such branch: $ReleaseBranch" }

    $behind = & git rev-list --count "$ReleaseBranch..master"
    if ($behind -eq '0') {
        "$ReleaseBranch already contains everything in master -- nothing to merge."
    } else {
        "Merging $behind new upstream commit(s) into $ReleaseBranch..."
        & git merge --no-edit master
        if ($LASTEXITCODE -ne 0) {
            throw "Merge conflict. This fork patches exactly one upstream-owned file -- " +
                  "the fork guard in .github/workflows/containers.yml. A conflict " +
                  "anywhere else means something new is being carried and is worth " +
                  "questioning. Resolve, then: git commit && git push origin $ReleaseBranch"
        }
        & git push origin $ReleaseBranch
        if ($LASTEXITCODE -ne 0) { throw "could not push $ReleaseBranch" }
    }

    Show-BannerState $ReleaseBranch

    # Tags are deliberately NOT pushed: upstream's release tags would trigger
    # this fork's tag-gated publishing workflows.
    Write-Host ""
    Write-Host "Sync complete."
} finally { Pop-Location }
