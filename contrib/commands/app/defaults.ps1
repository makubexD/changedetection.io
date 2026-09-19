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

Test-PodmanReady
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
