# Run changedetection.io under rootless Podman, then open it in a browser.
# Usage: .\contrib\podman\run.ps1 [-Tag dev] [-Port 5000] [-WithBrowser]
#
# -WithBrowser also starts sockpuppetbrowser (real Chrome) so the app can render
# JS-heavy pages and expose the Browser Steps / Visual Selector UI. Both
# containers go into one POD, which means they share a network namespace and
# therefore reach each other on localhost -- NOT by hostname. That is why the
# driver URL below is ws://localhost:3000 and not ws://browser-...:3000 as it is
# in podman-compose.yml.
param(
    [string]$Tag = 'dev',
    [int]$Port = 5000,
    [switch]$WithBrowser
)
$ErrorActionPreference = 'Stop'

$image       = "changedetection.io:$Tag"
$name        = 'changedetection'
$browserName = 'browser-sockpuppet-chrome'
$podName     = 'changedetection-pod'

# Replace any previous container of the same name; the named volume,
# and therefore every watch and its history, is untouched by this.
podman rm -f $name 2>$null | Out-Null

if (-not $WithBrowser) {
    podman run -d `
        --name $name `
        --restart unless-stopped `
        -p "127.0.0.1:${Port}:5000" `
        -v changedetection-data:/datastore `
        -e "BASE_URL=http://localhost:$Port" `
        $image
    if ($LASTEXITCODE -ne 0) { throw "podman run failed with exit code $LASTEXITCODE" }

    Write-Host "changedetection.io is starting on http://localhost:$Port"
    Write-Host "Follow the logs with: .\contrib\podman\logs.ps1"
    Write-Host "No browser: JS-rendered pages, Browser Steps and the Visual Selector"
    Write-Host "are unavailable. Re-run with -WithBrowser to enable them."
    return
}

# --- With browser: one pod, two containers -----------------------------------
podman rm -f $browserName 2>$null | Out-Null
podman pod rm -f $podName 2>$null | Out-Null

# The pod owns the published port; containers inside it must not publish their
# own. Port 3000 stays internal to the pod -- only the app needs to reach it.
podman pod create --name $podName -p "127.0.0.1:${Port}:5000" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "podman pod create failed with exit code $LASTEXITCODE" }

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
    docker.io/dgtlmoon/sockpuppetbrowser:latest
if ($LASTEXITCODE -ne 0) { throw "podman run (browser) failed with exit code $LASTEXITCODE" }

podman run -d `
    --pod $podName `
    --name $name `
    --restart unless-stopped `
    -v changedetection-data:/datastore `
    -e "BASE_URL=http://localhost:$Port" `
    -e "PLAYWRIGHT_DRIVER_URL=ws://localhost:3000" `
    $image
if ($LASTEXITCODE -ne 0) { throw "podman run failed with exit code $LASTEXITCODE" }

Write-Host "changedetection.io is starting on http://localhost:$Port (pod: $podName)"
Write-Host "Chrome is available -- the watch edit screen should now show"
Write-Host "'Browser Steps' and the Visual Selector. If it does not, the app cannot"
Write-Host "reach the browser; check: .\contrib\podman\logs.ps1 -Browser"
Write-Host "Follow the app logs with: .\contrib\podman\logs.ps1"
