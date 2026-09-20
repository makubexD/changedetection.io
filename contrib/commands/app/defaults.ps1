#: show the global defaults a new watch would inherit

<#
.SYNOPSIS
    Show what a NEW watch would inherit from this instance, before generating one.

.DESCRIPTION
    Runs inside the running container and reads the application's OWN datastore
    file, so the answer matches what the app actually has -- not a template's
    idea of the defaults. None of this is reachable over the API: there is no
    `GET /api/v1/settings`, and `GET /api/v1/tags` does not return a tag's
    url_match_pattern or its filters.

    Two things worth checking before you generate a watch:

      1. the global fetch backend, interval and filter lists a watch inherits
         by leaving a field unset
      2. every tag and its url_match_pattern -- a tag can attach to a new watch
         by matching its URL, not only by explicit assignment, and its filters
         then union with the watch's own rather than overriding them

    Secrets (the API token, the UI password) are reported as present or absent,
    never as their value.

.PARAMETER Json
    Print one JSON report instead of prose.

.EXAMPLE
    .\contrib\maku.ps1 app defaults
#>
param(
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

# UNLIKE 'site probe', there is no host-only fallback for this one -- it reads
# the LIVE datastore inside the container, and there is no substitute for
# that anywhere outside it. Said plainly here so a machine with no podman
# reads this as a real limitation, not a bug that 'site probe' avoided.
try {
    Test-PodmanReady
} catch {
    throw (New-Refusal ("$($_.Exception.Message)`nUnlike 'site probe', 'app defaults' has no host-only path -- " +
                        "it reads the live instance's own datastore, which only exists inside the container.") `
                       "run this on a machine with the stack up, or skip it and flag tags/globals as unchecked in the plan")
}
$container = (Get-PodmanNames).App

# Same check as 'site probe' -- the script arrives on the read-only mount that
# 'app start' adds, not in the image itself.
& podman exec $container test -f /maku-runtime/instance.py 2>$null
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "The container has no /maku-runtime/instance.py, so it is running without the fork's runtime mount." `
                       ".\contrib\maku.ps1 app start -WithBrowser   (restarts with the mount; your watches are untouched)")
}

$defaultsArgs = @('exec', $container, 'python', '/maku-runtime/instance.py')
if ($Json) { $defaultsArgs += '--json' }

& podman @defaultsArgs
if ($LASTEXITCODE -ne 0) { throw "app defaults failed (exit $LASTEXITCODE)." }
