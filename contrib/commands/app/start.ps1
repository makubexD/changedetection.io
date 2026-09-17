#: start the app, optionally with real Chrome

<#
.SYNOPSIS
    Start changedetection.io under rootless Podman.

.DESCRIPTION
    SAFE TO RE-RUN, ALWAYS. It first clears whatever the last run left behind --
    container, browser container and pod alike -- so re-running after a pull, or
    switching -WithBrowser on and off, needs no manual cleanup.

    YOUR DATA IS SAFE. This replaces the container, never the volume: every watch
    and its history lives in the named volume changedetection-data and is
    reattached to the new container.

.PARAMETER WithBrowser
    Also start sockpuppetbrowser (real Chrome) so the app can render JS-heavy
    pages and expose Browser Steps and the Visual Selector. Both containers go
    into one POD, so they share a network namespace and reach each other on
    localhost -- which is why the driver URL is ws://localhost:3000 here and
    ws://browser-sockpuppet-chrome:3000 under compose or Quadlet.

.PARAMETER Image
    Run a published image instead of the one built from this repo.

.PARAMETER Port
    Host port to publish on. Rootless cannot bind below 1024.

.EXAMPLE
    .\contrib\maku.ps1 app start -WithBrowser
.EXAMPLE
    .\contrib\maku.ps1 app start -Image ghcr.io/makubexd/changedetection.io:stable
#>
param(
    [switch]$WithBrowser,
    [string]$Image,
    [int]$Port = 5000
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force

Test-PodmanReady
$n     = Get-PodmanNames
$image = if ($Image) { $Image } else { Get-ImagePin 'AppLocal' }

Remove-Stack @($n.App, $n.Browser) $n.Pod

$spec = @{
    Name = $n.App; Image = $image; Volume = $n.Volume
    Port = $Port;  Pod = $null;    DriverUrl = $null; Restart = $true
}

if ($WithBrowser) {
    New-AppPod $n.Pod $Port
    # Chrome first, so it is accepting connections by the time a fetch happens.
    Start-BrowserContainer $n.Browser $n.Pod
    $spec.Pod       = $n.Pod
    $spec.DriverUrl = 'ws://localhost:3000'
}

if (-not (Start-AppContainer $spec)) {
    throw "podman run failed. Port $Port may be in use -- try -Port 5001, or see what is left over with: podman ps -a ; podman pod ps"
}

Write-Pass 'start' "http://localhost:$Port$(if ($WithBrowser) { "  (pod $($n.Pod))" })"
Write-Host ""
if ($WithBrowser) {
    Write-Host "Confirm Chrome is wired up:  .\contrib\maku.ps1 app verify -WithBrowser"
    Write-Host "Existing watches keep the fetcher they were saved with -- see"
    Write-Host "contrib/podman/VERIFY.md for the Fetch Method check."
} else {
    Write-Host "No browser: JS-rendered pages, Browser Steps and the Visual Selector"
    Write-Host "are unavailable. Re-run with -WithBrowser to enable them."
}
Write-Host "Logs:  .\contrib\maku.ps1 app logs"
