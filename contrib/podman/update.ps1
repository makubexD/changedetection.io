# Pull the latest code and restart changedetection.io, rebuilding the image
# only when the pull actually touched something the image contains.
#
# Usage:
#   .\contrib\podman\update.ps1                 # pull, maybe rebuild, restart
#   .\contrib\podman\update.ps1 -WithBrowser    # ...and start Chrome alongside
#   .\contrib\podman\update.ps1 -Image ghcr.io/dgtlmoon/changedetection.io:latest
#
# This is the "I just want the newest version running" command on a machine
# that only DEPLOYS. It pulls the branch you already have checked out and
# fast-forwards it; it never merges, never switches branch and never pushes.
#
# It is NOT a branch-maintenance script. Bringing new upstream commits into a
# release branch is a different job with different failure modes -- a merge,
# conflicts to resolve, a push -- and belongs on the machine where the work
# happens. Do that there, then run this here.
#
# YOUR DATA IS SAFE. Everything below replaces the container, never the named
# volume, so watches and history survive -- run.ps1 does the actual start and
# carries that guarantee.
param(
    [string]$Tag = 'dev',
    # Deploy a published image instead of building from this repo. When set,
    # nothing is ever built and the rebuild check is skipped entirely.
    [string]$Image,
    [int]$Port = 5000,
    [switch]$WithBrowser
)
$ErrorActionPreference = 'Stop'

# Same guard as run.ps1 and test.ps1: PowerShell 7.4+ turns any non-zero native
# exit code into a terminating error, and git uses exit codes to answer
# questions rather than to report failure. Exit codes are checked by hand.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Resolve-Path "$PSScriptRoot\..\.."

# The Dockerfile copies these paths and nothing else, so only a change to one
# of them can change the image. Kept in step with the table in README.md
# ("What 'the image changed' means") -- if one moves, both move.
$imageInputs = @(
    'Dockerfile'
    'docker-entrypoint.sh'
    'requirements.txt'
    'changedetection.py'
    'changedetectionio/'
    'docs/api-spec.yaml'
)

function Assert-CleanTree {
    $dirty = & git status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "not a git repository: $repoRoot" }
    if ($dirty) {
        throw "Working tree is not clean -- commit or stash first:`n$dirty"
    }
}

function Get-CurrentBranch {
    $branch = & git rev-parse --abbrev-ref HEAD
    if ($LASTEXITCODE -ne 0) { throw "could not read the current branch" }
    if ($branch -eq 'HEAD') {
        throw "HEAD is detached -- check out the branch you deploy from first."
    }
    return $branch
}

# Which image inputs changed between two commits. Empty means the pull cannot
# have changed the image, so the build is genuinely skippable rather than
# merely probably skippable.
function Get-ChangedImageInputs([string]$before, [string]$after) {
    $changed = & git diff --name-only $before $after -- @imageInputs
    if ($LASTEXITCODE -ne 0) { throw "could not diff $before..$after" }
    return @($changed | Where-Object { $_ })
}

Assert-CleanTree
$branch = Get-CurrentBranch
$before = & git rev-parse HEAD

Write-Host "Pulling $branch..."
& git pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw "git pull --ff-only failed. This clone has local commits or has " +
          "diverged from its remote; it is meant to only ever follow. " +
          "Resolve by hand, or re-clone."
}

$after = & git rev-parse HEAD
if ($before -eq $after) {
    Write-Host "Already up to date at $($after.Substring(0,8))."
} else {
    Write-Host "Updated $($before.Substring(0,8)) -> $($after.Substring(0,8))."
}

if ($Image) {
    Write-Host "Deploying $Image -- nothing to build."
} else {
    $changed = Get-ChangedImageInputs $before $after
    if ($changed.Count -gt 0) {
        Write-Host "Image inputs changed, rebuilding:"
        $changed | ForEach-Object { Write-Host "    $_" }
        & "$PSScriptRoot\build.ps1" -Tag $Tag
    } else {
        Write-Host "No image inputs changed -- reusing changedetection.io:$Tag."
    }
}

# run.ps1 clears the previous container, browser container and pod itself, so
# there is nothing to tear down here first.
$runArgs = @{ Port = $Port }
if ($Image)       { $runArgs['Image'] = $Image } else { $runArgs['Tag'] = $Tag }
if ($WithBrowser) { $runArgs['WithBrowser'] = $true }

& "$PSScriptRoot\run.ps1" @runArgs
