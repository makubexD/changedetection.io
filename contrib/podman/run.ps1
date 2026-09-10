# Start changedetection.io under rootless Podman. The quickest path: one
# command, no compose binary, no systemd.
#
# Usage:
#   .\contrib\podman\run.ps1                  # runs the image build.ps1 made
#   .\contrib\podman\run.ps1 -WithBrowser     # ...and real Chrome alongside it
#   .\contrib\podman\run.ps1 -Image ghcr.io/dgtlmoon/changedetection.io:latest
#
# Defaults to changedetection.io:<Tag>, which build.ps1 produces. Pass -Image
# to run a published image instead and skip building altogether.
#
# SAFE TO RE-RUN, ALWAYS. It first clears whatever the last run left behind --
# container, browser container and pod alike -- so re-running after a git pull,
# or switching -WithBrowser on and off, needs no manual cleanup.
#
# YOUR DATA IS SAFE. This replaces the container, never the volume: every
# watch and its history lives in the named volume changedetection-data, and
# it is reattached to the new container. Turning -WithBrowser on or off on a
# live install is therefore safe.
#
# -WithBrowser also starts sockpuppetbrowser (real Chrome) so the app can render
# JS-heavy pages and expose the Browser Steps / Visual Selector UI. Both
# containers go into one POD, which means they share a network namespace and
# therefore reach each other on localhost -- NOT by hostname. That is why the
# driver URL below is ws://localhost:3000 and not ws://browser-...:3000 as it is
# in podman-compose.yml.
param(
    [string]$Tag = 'dev',
    # Run a prebuilt or pulled image instead of one built from this repo.
    # Mirrors test.ps1's -Image so both scripts take the same arguments.
    [string]$Image,
    [int]$Port = 5000,
    [switch]$WithBrowser
)
$ErrorActionPreference = 'Stop'

# The cleanup below is expected to fail when there is nothing to remove.
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error,
# which would abort the script before it starts anything. Exit codes are checked
# by hand instead, everywhere it matters. Same guard as test.ps1.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Turns "exit code 126" into something you can act on. Only consulted when a
# podman command has already failed, so a wrong guess here can never block a
# start that would otherwise have worked.
function Get-PortHolder([int]$p) {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    $ids = @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty OwningProcess -Unique)
    if (-not $ids) { return $null }
    $names = @($ids |
               ForEach-Object { (Get-Process -Id $_ -ErrorAction SilentlyContinue).ProcessName } |
               Where-Object { $_ } | Sort-Object -Unique)
    if ($names) { return ($names -join ', ') }
    return 'an unidentified process'
}

function Stop-WithReason([string]$what, [int]$code, [int]$p) {
    $holder = Get-PortHolder $p
    if ($holder) {
        throw ("$what failed (exit $code): port $p is already in use by $holder. " +
               "Stop it, or start somewhere else: .\contrib\podman\run.ps1 -Port 5001")
    }
    throw ("$what failed with exit code $code. See what is left over with: " +
           "podman ps -a  and  podman pod ps")
}

$image       = if ($Image) { $Image } else { "changedetection.io:$Tag" }
$name        = 'changedetection'
$browserName = 'browser-sockpuppet-chrome'
$podName     = 'changedetection-pod'
# Pinned by DIGEST, not :latest -- see contrib/podman/README.md. The tag is
# rebuilt often and bakes in whatever Chrome Stable is current that day, so
# :latest changes Chrome under you without warning.
$browserImage = 'docker.io/dgtlmoon/sockpuppetbrowser@sha256:a61e64a694fef3b6d375a3c7c7dd7d74b1166a48b231cd98870b78f244deef79'

# Clear BOTH topologies before starting, every time. A previous run may have
# left either one behind, and both publish $Port:
#   plain         -> the container named $name publishes it
#   -WithBrowser  -> the POD named $podName publishes it, via its infra container
# Removing only the container leaves the pod still holding the port, and the
# next plain start then dies with "address already in use" (exit 126). Clearing
# both makes this script safe to re-run and safe to switch modes with.
#
# The named volume -- every watch and its history -- is untouched by any of it.
podman rm -f $name $browserName 2>$null | Out-Null
podman pod rm -f $podName 2>$null | Out-Null

if (-not $WithBrowser) {
    podman run -d `
        --name $name `
        --restart unless-stopped `
        -p "127.0.0.1:${Port}:5000" `
        -v changedetection-data:/datastore `
        -e "BASE_URL=http://localhost:$Port" `
        $image
    if ($LASTEXITCODE -ne 0) { Stop-WithReason 'podman run' $LASTEXITCODE $Port }

    Write-Host "changedetection.io is starting on http://localhost:$Port"
    Write-Host "Follow the logs with: .\contrib\podman\logs.ps1"
    Write-Host "No browser: JS-rendered pages, Browser Steps and the Visual Selector"
    Write-Host "are unavailable. Re-run with -WithBrowser to enable them."
    return
}

# --- With browser: one pod, two containers -----------------------------------
# (Cleanup already happened above, for both topologies.)

# The pod owns the published port; containers inside it must not publish their
# own. Port 3000 stays internal to the pod -- only the app needs to reach it.
podman pod create --name $podName -p "127.0.0.1:${Port}:5000" | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-WithReason 'podman pod create' $LASTEXITCODE $Port }

# Chrome first, so it is accepting connections by the time a fetch happens.
# --shm-size=2g: Podman defaults /dev/shm to 64MB and Chrome dies with
# "Target closed" / renderer failures well before that is genuinely exhausted.
podman run -d `
    --pod $podName `
    --name $browserName `
    --restart unless-stopped `
    --shm-size=2g `
    --cap-add SYS_ADMIN `
    -e SCREEN_WIDTH=1920 `
    -e SCREEN_HEIGHT=1024 `
    -e SCREEN_DEPTH=16 `
    -e MAX_CONCURRENT_CHROME_PROCESSES=10 `
    $browserImage
if ($LASTEXITCODE -ne 0) { throw "podman run (browser) failed with exit code $LASTEXITCODE" }

# DEFAULT_FETCH_BACKEND makes new watches use Chrome instead of the plain HTTP
# fetcher. Without it the browser runs but nothing points at it: every watch
# keeps fetching plain HTML until you change Fetch Method by hand, one at a time.
# It seeds the settings DEFAULT, so it takes effect on a FRESH datastore -- an
# existing install keeps its saved value, changed under
# Settings -> Fetching -> Fetch Method.
podman run -d `
    --pod $podName `
    --name $name `
    --restart unless-stopped `
    -v changedetection-data:/datastore `
    -e "BASE_URL=http://localhost:$Port" `
    -e "PLAYWRIGHT_DRIVER_URL=ws://localhost:3000" `
    -e "DEFAULT_FETCH_BACKEND=html_webdriver" `
    $image
if ($LASTEXITCODE -ne 0) { Stop-WithReason 'podman run' $LASTEXITCODE $Port }

Write-Host "changedetection.io is starting on http://localhost:$Port (pod: $podName)"
Write-Host ""
Write-Host "To confirm Chrome is wired up: open a watch -> Edit -> Request and read"
Write-Host "the Fetch Method labels. One must say:"
Write-Host "    Playwright Chromium/Javascript via 'ws://localhost:3000'"
Write-Host "Seeing only 'WebDriver Chrome/Javascript' means the app did not get the"
Write-Host "driver URL. Existing watches keep the fetcher they were saved with --"
Write-Host "select the Playwright option and Save, or change the default under"
Write-Host "Settings -> Fetching -> Fetch Method."
Write-Host ""
Write-Host "App logs:     .\contrib\podman\logs.ps1"
Write-Host "Chrome logs:  .\contrib\podman\logs.ps1 -Browser"
