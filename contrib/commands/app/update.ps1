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
    $changed = @(& git diff --name-only $before $after -- @imageInputs | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw "could not diff $before..$after" }

    if ($changed.Count -gt 0) {
        Write-Host "Image inputs changed, rebuilding:"
        $changed | ForEach-Object { Write-Host "    $_" }
        & (Join-Path $PSScriptRoot 'build.ps1')
        if ($LASTEXITCODE -ne 0) { throw "build failed -- not restarting." }
    } else {
        Write-Host "No image inputs changed -- reusing the existing image."
    }
}

# 'app start' clears the previous container, browser container and pod itself,
# so there is nothing to tear down here first.
$startArgs = @{ Port = $Port }
if ($Image)       { $startArgs['Image'] = $Image }
if ($WithBrowser) { $startArgs['WithBrowser'] = $true }

& (Join-Path $PSScriptRoot 'start.ps1') @startArgs
