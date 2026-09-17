#: pull new code, rebuild only if needed, and restart

<#
.SYNOPSIS
    Bring a deployment machine up to the latest code in one command.

.DESCRIPTION
    Pulls the branch you already have checked out and fast-forwards it. It never
    merges, never switches branch and never pushes, so it is safe on a machine
    that only deploys.

    Bringing new UPSTREAM commits into the release branch is a different job with
    different failure modes -- a merge, a CI gate, a push -- and lives in
    'fork sync', on the machine where the work happens. Run that there, then run
    this here.

    YOUR DATA IS SAFE. 'app start' does the actual start and replaces the
    container, never the volume.

.PARAMETER WithBrowser
    Passed straight through to 'app start'.

.PARAMETER Image
    Deploy a published image instead of building. Nothing is built and the
    rebuild check is skipped entirely.

.PARAMETER Port
    Passed straight through to 'app start'.

.EXAMPLE
    .\contrib\maku.ps1 app update -WithBrowser
#>
param(
    [switch]$WithBrowser,
    [string]$Image,
    [int]$Port = 5000
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

# The Dockerfile copies these paths and nothing else, so only a change to one of
# them can change the image. Everything in contrib/ is absent from the image, so
# a pull that only touches tooling needs a restart, not a rebuild.
$imageInputs = @(
    'Dockerfile'
    'docker-entrypoint.sh'
    'requirements.txt'
    'changedetection.py'
    'changedetectionio/'
    'docs/api-spec.yaml'
)

# Whether the image on THIS machine still matches the source in this clone, and
# in one sentence why not.
#
# THE QUESTION IS NOT "DID THIS PULL CHANGE ANYTHING". It used to be: the check
# diffed the pull's own range, $before..$after. So the first run after a sync
# pulled, saw Dockerfile and requirements.txt move, and went to build -- and if
# anything after the pull failed (a build error, a podman that was not up, a
# closed laptop), the NEXT run pulled nothing, diffed an empty range, announced
# "no image inputs changed" and started the old image against the new source.
# Silently, and permanently: every later run agreed with it. A stale deployment
# that reports itself as up to date is worse than one that fails.
#
# So the comparison runs from the commit the image itself carries. Anything that
# leaves that unknowable -- no image, an unreachable podman, an image built
# before the label existed -- is a rebuild, because "cannot prove it is current"
# and "is current" must never take the same branch.
function Get-RebuildDecision([string]$Image, [string[]]$Paths) {
    $builtFrom = Get-ImageRevision $Image
    $result = @{ BuiltFrom = $builtFrom; Changed = @(); Reason = $null }

    if (-not $builtFrom) {
        $result.Reason = "no local image '$Image' carrying a revision label"
    } elseif (-not (Test-CommitPresent $builtFrom)) {
        $result.Reason = "the image was built from $($builtFrom.Substring(0,8)), which is not in this clone"
    } else {
        $result.Changed = @(& git diff --name-only $builtFrom HEAD -- @Paths | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw "could not diff $builtFrom..HEAD" }
        if ($result.Changed.Count -gt 0) {
            $result.Reason = "image inputs changed since $($builtFrom.Substring(0,8)):"
        }
    }
    return [pscustomobject]$result
}

function Test-CommitPresent([string]$Sha) {
    & git cat-file -e "$Sha^{commit}" 2>$null
    return $LASTEXITCODE -eq 0
}

# Before the pull, not after it. Every path through this command ends in podman
# -- the rebuild check reads a label off an image, and the start needs it
# outright -- so an unusable podman is fatal either way, and finding that out
# first costs nothing. It also keeps the failure readable: an absent binary
# raises CommandNotFoundException, which $ErrorActionPreference='Stop' turns
# into a terminating error before any exit code can be read, so without this the
# reader gets "the term 'podman' is not recognized" from inside a label lookup.
Test-PodmanReady
Assert-CleanTree
$branch = Get-CurrentBranch
$before = (& git rev-parse HEAD).Trim()

Write-Host "Pulling $branch..."
& git pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw ("git pull --ff-only failed. This clone has local commits or has diverged " +
           "from its remote; it is meant to only ever follow. Resolve by hand, or re-clone.")
}

$after = (& git rev-parse HEAD).Trim()
if ($before -eq $after) {
    Write-Host "Already up to date at $($after.Substring(0,8))."
} else {
    Write-Host "Updated $($before.Substring(0,8)) -> $($after.Substring(0,8))."
}

if ($Image) {
    Write-Host "Deploying $Image -- nothing to build."
} else {
    $decision = Get-RebuildDecision (Get-ImagePin 'AppLocal') $imageInputs
    if ($decision.Reason) {
        Write-Host "Rebuilding -- $($decision.Reason)"
        $decision.Changed | ForEach-Object { Write-Host "    $_" }
        & (Join-Path $PSScriptRoot 'build.ps1')
        if ($LASTEXITCODE -ne 0) { throw "build failed -- not restarting." }
    } else {
        Write-Host "Image is current at $($decision.BuiltFrom.Substring(0,8)) -- reusing it."
    }
}

# 'app start' clears the previous container, browser container and pod itself,
# so there is nothing to tear down here first.
$startArgs = @{ Port = $Port }
if ($Image)       { $startArgs['Image'] = $Image }
if ($WithBrowser) { $startArgs['WithBrowser'] = $true }

& (Join-Path $PSScriptRoot 'start.ps1') @startArgs
