# Build the changedetection.io image locally with Podman (Buildah).
# Usage: .\contrib\podman\build.ps1 [-Tag dev] [-NoCache]
param(
    [string]$Tag = 'dev',
    [switch]$NoCache
)
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path "$PSScriptRoot\..\.."
$image    = "changedetection.io:$Tag"

$buildArgs = @('build', '-t', $image, '-f', "$repoRoot\Dockerfile")
if ($NoCache) {
    # Fallback for older Buildah versions that mishandle the Dockerfile's
    # RUN --mount=type=cache directives.
    $buildArgs += '--no-cache'
}
$buildArgs += $repoRoot

Write-Host "podman $($buildArgs -join ' ')"
& podman @buildArgs
if ($LASTEXITCODE -ne 0) { throw "podman build failed with exit code $LASTEXITCODE" }

Write-Host "Built $image"
