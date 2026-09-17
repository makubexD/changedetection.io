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
$n = Get-PodmanNames

# Asked BEFORE the line below, which needs $Image to still mean what the caller
# typed. PowerShell variable names are case-INSENSITIVE, so $image and $Image are
# one variable: assigning the default to $image overwrites the parameter, and
# anything downstream testing $Image would find it always set.
$imageWasGiven = [bool]$Image

$image = if ($Image) { $Image } else { Get-ImagePin 'AppLocal' }

# BEFORE Remove-Stack: a run that cannot succeed must not first tear down the
# deployment that was working. A mistyped -Image is the ordinary way to get here.
& podman image exists $image
if ($LASTEXITCODE -ne 0) {
    # The fix depends on WHICH image is missing. Offering '-Image' to someone who
    # just passed -Image reads as though the command did not notice what they
    # typed -- and the actual mistake there is almost always the name itself.
    $fix = if ($imageWasGiven) {
        "  fix: check the name, or pull it first:  podman pull $image"
    } else {
        "  fix: .\contrib\maku.ps1 app build" + [Environment]::NewLine +
        "  (or pass -Image to run a published one instead)"
    }
    throw ("the image '$image' does not exist, so there is nothing to start." +
           [Environment]::NewLine + $fix)
}

Remove-Stack @($n.App, $n.Browser) $n.Pod

# AFTER Remove-Stack, and that order is the whole point: this command is meant to
# be re-run over its own deployment, which is holding the port until the line
# above removes it. Asked any earlier, the everyday restart would refuse itself.
# Whatever still answers here is something else.
#
# Worth asking at all because -WithBrowser publishes through the POD, and a pod's
# port is bound by its infra container when the FIRST container starts -- so a
# taken port kills the browser run with 'internal libpod error' (exit 126),
# before anything below can report it.
if (Test-PortInUse $Port) {
    throw ("something else is already serving 127.0.0.1:$Port." + [Environment]::NewLine +
           "  fix: stop it, or publish this one elsewhere with -Port 5001" + [Environment]::NewLine +
           "  to see what is there:  podman ps -a ; podman pod ps")
}

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
    # The two ordinary causes -- no image, port taken -- are now refused at
    # preflight by name, so this is genuinely "something else" and must not
    # guess. podman printed its own reason immediately above.
    throw ("podman run failed (see podman's message above)." + [Environment]::NewLine +
           "  what is left over:  podman ps -a ; podman pod ps")
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
