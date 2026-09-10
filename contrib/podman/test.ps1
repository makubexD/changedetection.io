# Smoke-test changedetection.io under rootless Podman.
#
# Runs the build / run / responds-on-:5000 / data-persists sequence from
# TESTING.md as one command, and exits non-zero if any stage fails.
#
# Deliberately uses its OWN container, pod and volume names, so running this can
# never touch or destroy a real `changedetection` deployment's watches.
#
# Usage:
#   .\contrib\podman\test.ps1
#   .\contrib\podman\test.ps1 -WithBrowser
#   .\contrib\podman\test.ps1 -Image ghcr.io/dgtlmoon/changedetection.io:latest
#   .\contrib\podman\test.ps1 -KeepRunning -Port 5001
param(
    [string]$Tag = 'dev',
    # Test a prebuilt or pulled image instead of building from this repo.
    [string]$Image,
    [int]$Port = 5000,
    [int]$TimeoutSec = 180,
    [switch]$SkipBuild,
    # Fallback for older Buildah versions that mishandle the Dockerfile's
    # RUN --mount=type=cache directives.
    [switch]$NoCache,
    # Also start sockpuppetbrowser and verify the app can actually reach it.
    [switch]$WithBrowser,
    # Leave the container up afterwards for the manual steps in TESTING.md.
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'

# Several podman calls below are expected to fail (removing a container that
# is not there). PowerShell 7.4+ turns a non-zero native exit code into a
# terminating error, which would abort those. Exit codes are checked by hand
# instead, everywhere it matters.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot    = Resolve-Path "$PSScriptRoot\..\.."
$container   = 'cdio-smoketest'
$browser     = 'cdio-smoketest-browser'
$pod         = 'cdio-smoketest-pod'
$volume      = 'cdio-smoketest-data'
$image       = if ($Image) { $Image } else { "changedetection.io:$Tag" }
# Pinned by digest so a browser rebuild cannot turn a green smoke test red.
$browserImage = 'docker.io/dgtlmoon/sockpuppetbrowser@sha256:a61e64a694fef3b6d375a3c7c7dd7d74b1166a48b231cd98870b78f244deef79'
$baseUrl     = "http://localhost:$Port/"
# In a pod both containers share a network namespace, so the app reaches Chrome
# on localhost. On a network (podman-compose, Quadlet) it would be the hostname.
$driverUrl   = 'ws://localhost:3000'

$failed = @()

function Write-Stage([string]$Name) {
    Write-Host ""
    Write-Host "-- $Name" -ForegroundColor Cyan
}
function Write-Pass([string]$Name) {
    Write-Host "PASS  $Name" -ForegroundColor Green
}
function Write-Fail([string]$Name, [string]$Detail) {
    Write-Host "FAIL  $Name" -ForegroundColor Red
    if ($Detail) { Write-Host "      $Detail" -ForegroundColor Red }
    $script:failed += $Name
}

# Dumps whatever the containers managed to log. Called before every early exit,
# because the log is normally the only thing that says why a stage failed.
function Show-ContainerLogs {
    Write-Host ""
    Write-Host "--- podman logs $container ---" -ForegroundColor Yellow
    podman logs --tail 80 $container 2>&1 | Write-Host
    if ($WithBrowser) {
        Write-Host "--- podman logs $browser ---" -ForegroundColor Yellow
        podman logs --tail 40 $browser 2>&1 | Write-Host
    }
    Write-Host "--- end of logs ---" -ForegroundColor Yellow
}

function Remove-TestContainers {
    podman rm -f $container 2>$null | Out-Null
    if ($WithBrowser) {
        podman rm -f $browser 2>$null | Out-Null
        podman pod rm -f $pod 2>$null | Out-Null
    }
}

function Start-TestStack {
    if (-not $WithBrowser) {
        podman run -d `
            --name $container `
            -p "127.0.0.1:${Port}:5000" `
            -v "${volume}:/datastore" `
            -e "BASE_URL=$baseUrl" `
            $image | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    # The pod owns the published port; containers inside must not publish their own.
    podman pod create --name $pod -p "127.0.0.1:${Port}:5000" | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }

    podman run -d `
        --pod $pod `
        --name $browser `
        --shm-size=2g `
        --cap-add SYS_ADMIN `
        -e SCREEN_WIDTH=1920 `
        -e SCREEN_HEIGHT=1024 `
        -e MAX_CONCURRENT_CHROME_PROCESSES=10 `
        $browserImage | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }

    podman run -d `
        --pod $pod `
        --name $container `
        -v "${volume}:/datastore" `
        -e "BASE_URL=$baseUrl" `
        -e "PLAYWRIGHT_DRIVER_URL=$driverUrl" `
        $image | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Polls until the app answers or the deadline passes. A listening port is not
# enough on first start -- the app does one-time setup before it serves.
function Wait-ForApp([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            # Not up yet. Keep waiting until the deadline.
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

Write-Host "changedetection.io Podman smoke test" -ForegroundColor White
Write-Host "  image:     $image"
Write-Host "  container: $container"
Write-Host "  volume:    $volume"
Write-Host "  url:       $baseUrl"
if ($WithBrowser) {
    Write-Host "  browser:   $browserImage (pod $pod, $driverUrl)"
}

# --- 0. Preflight ------------------------------------------------------------
Write-Stage "0. Preflight"

podman --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "preflight" "podman not found. See TESTING.md step 1."
    exit 1
}
podman info | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "preflight" "podman info failed -- the machine is probably not running. Try: podman machine start   (TESTING.md step 2)"
    exit 1
}
Write-Pass "preflight"

# --- 1. Build ----------------------------------------------------------------
if ($Image -or $SkipBuild) {
    Write-Stage "1. Build (skipped)"
    Write-Host "      using $image as-is"
} else {
    Write-Stage "1. Build"
    $buildArgs = @('build', '-t', $image, '-f', "$repoRoot\Dockerfile")
    if ($NoCache) { $buildArgs += '--no-cache' }
    $buildArgs += $repoRoot

    Write-Host "      podman $($buildArgs -join ' ')"
    & podman @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "build" "podman build exited $LASTEXITCODE. On an older Buildah, retry with -NoCache."
        exit 1
    }
    Write-Pass "build"
}

# --- 2. Clean up anything left by a previous run -----------------------------
Write-Stage "2. Clean slate"
Remove-TestContainers
Write-Pass "clean slate"

# --- 3. Run ------------------------------------------------------------------
Write-Stage "3. Run"
if (-not (Start-TestStack)) {
    Write-Fail "run" "podman run failed. If it is a port conflict, pass -Port with something free."
    exit 1
}
Write-Pass "run"

# --- 4. Responds on the port -------------------------------------------------
Write-Stage "4. HTTP 200 on $baseUrl (up to ${TimeoutSec}s)"
if (-not (Wait-ForApp $TimeoutSec)) {
    Write-Fail "http" "no 200 within ${TimeoutSec}s"
    Show-ContainerLogs
    if (-not $KeepRunning) { Remove-TestContainers }
    exit 1
}
Write-Pass "http"

# --- 4b. The app can actually reach Chrome -----------------------------------
# Checked from INSIDE the app container, which is the connection that matters.
# Testing it from the host would prove nothing: port 3000 is pod-internal, and a
# browser that is running but unreachable is exactly the failure this catches --
# the app would silently fall back and the Browser Steps UI would never appear.
if ($WithBrowser) {
    Write-Stage "4b. App -> browser reachability on $driverUrl"

    $reached = $false
    for ($i = 0; $i -lt 15; $i++) {
        podman exec $container python -c "import socket; socket.create_connection(('localhost', 3000), 5).close()" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $reached = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $reached) {
        Write-Fail "browser" "the app container cannot open a connection to localhost:3000"
        Show-ContainerLogs
        if (-not $KeepRunning) { Remove-TestContainers }
        exit 1
    }

    # And that the app was actually told about it -- reachable but unconfigured
    # looks identical from the outside.
    $envSet = podman exec $container sh -c "echo \$PLAYWRIGHT_DRIVER_URL" 2>$null
    if (($envSet | Out-String).Trim() -ne $driverUrl) {
        Write-Fail "browser" "PLAYWRIGHT_DRIVER_URL is '$(($envSet | Out-String).Trim())', expected '$driverUrl'"
        if (-not $KeepRunning) { Remove-TestContainers }
        exit 1
    }
    Write-Pass "browser"
}

# --- 5. Data survives the container being destroyed --------------------------
# The point of the named volume: rootless Podman maps container root to an
# unprivileged uid, so a host bind mount would arrive unwritable. This proves
# the volume is real and outlives the container.
Write-Stage "5. Persistence across container removal"

podman exec $container sh -c "echo persisted-ok > /datastore/.smoketest" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "persistence" "could not write to /datastore -- check the volume mount"
    Show-ContainerLogs
    if (-not $KeepRunning) { Remove-TestContainers }
    exit 1
}

# Only the app container is replaced; the browser and pod stay up.
podman rm -f $container 2>$null | Out-Null

if ($WithBrowser) {
    podman run -d --pod $pod --name $container `
        -v "${volume}:/datastore" `
        -e "BASE_URL=$baseUrl" `
        -e "PLAYWRIGHT_DRIVER_URL=$driverUrl" `
        $image | Out-Null
} else {
    podman run -d --name $container `
        -p "127.0.0.1:${Port}:5000" `
        -v "${volume}:/datastore" `
        -e "BASE_URL=$baseUrl" `
        $image | Out-Null
}
if ($LASTEXITCODE -ne 0) {
    Write-Fail "persistence" "container did not come back up after removal"
    exit 1
}

# Only the container needs to be running to read the file, not the whole app,
# so this waits on exec rather than on HTTP.
$marker = $null
for ($i = 0; $i -lt 15; $i++) {
    $marker = (podman exec $container cat /datastore/.smoketest 2>$null)
    if ($LASTEXITCODE -eq 0 -and $marker) { break }
    Start-Sleep -Seconds 2
}

if (($marker | Out-String).Trim() -ne 'persisted-ok') {
    Write-Fail "persistence" "marker did not survive: got '$(($marker | Out-String).Trim())'"
    Show-ContainerLogs
    if (-not $KeepRunning) { Remove-TestContainers }
    exit 1
}
podman exec $container rm -f /datastore/.smoketest 2>$null | Out-Null
Write-Pass "persistence"

# --- 6. Teardown -------------------------------------------------------------
if ($KeepRunning) {
    Write-Stage "6. Teardown (skipped)"
    Write-Host "      $container is still running on $baseUrl"
    if ($WithBrowser) {
        Write-Host "      remove it with: podman pod rm -f $pod; podman volume rm $volume"
    } else {
        Write-Host "      remove it with: podman rm -f $container; podman volume rm $volume"
    }
} else {
    Write-Stage "6. Teardown"
    Remove-TestContainers
    podman volume rm $volume 2>$null | Out-Null
    Write-Pass "teardown"
}

# --- Summary -----------------------------------------------------------------
Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "SMOKE TEST FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
$what = if ($WithBrowser) { "built, ran, served $baseUrl, reached Chrome, and kept its data." }
        else              { "built, ran, served $baseUrl, and kept its data." }
Write-Host "SMOKE TEST PASSED -- $what" -ForegroundColor Green
Write-Host "Steps 6 and 8 of TESTING.md (functional check, compose, kube) are still manual."
exit 0
