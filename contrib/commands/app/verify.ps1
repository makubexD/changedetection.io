#: prove a deployment works end to end, then tear it down

<#
.SYNOPSIS
    Smoke-test the image: it runs, it serves, it can reach Chrome, its data survives.

.DESCRIPTION
    Uses its OWN container, pod and volume names, so running this can never touch
    or destroy a real deployment's watches.

    It does NOT build. Verifying and building are separate jobs:
        .\contrib\maku.ps1 app build
        .\contrib\maku.ps1 app verify -WithBrowser

.PARAMETER WithBrowser
    Also start Chrome and verify the app can actually reach it, was told where it
    is, and defaults new watches to it. A port being open proves none of those.

.PARAMETER Image
    Verify a published image instead of the locally built one.

.PARAMETER Port
    Host port to publish on during the test.

.PARAMETER KeepRunning
    Leave it up afterwards for the manual checks in contrib/podman/VERIFY.md.

.EXAMPLE
    .\contrib\maku.ps1 app verify -WithBrowser
#>
param(
    [switch]$WithBrowser,
    [string]$Image,
    [int]$Port = 5000,
    [switch]$KeepRunning
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Use-NativeExitCodes

$container = 'cdio-smoketest'
$browser   = 'cdio-smoketest-browser'
$pod       = 'cdio-smoketest-pod'
$volume    = 'cdio-smoketest-data'
$image     = if ($Image) { $Image } else { Get-ImagePin 'AppLocal' }
$baseUrl   = "http://localhost:$Port/"
$driverUrl = 'ws://localhost:3000'
$timeout   = 180

function New-Spec([string]$pod) {
    return @{
        Name = $container; Image = $image; Volume = $volume; Port = $Port
        Pod  = $pod; DriverUrl = $(if ($WithBrowser) { $driverUrl } else { $null }); Restart = $false
    }
}

# The log is normally the only thing that says why a stage failed, so it is
# dumped before every early exit rather than left to be fished out afterwards.
function Show-Logs {
    Write-Host ""
    Write-Host "--- podman logs $container ---" -ForegroundColor Yellow
    & podman logs --tail 80 $container 2>&1 | Write-Host
    if ($WithBrowser) {
        Write-Host "--- podman logs $browser ---" -ForegroundColor Yellow
        & podman logs --tail 40 $browser 2>&1 | Write-Host
    }
    Write-Host "--- end of logs ---" -ForegroundColor Yellow
}

function Stop-Verify([string]$Stage, [string]$Detail, [switch]$WithLogs) {
    Write-Fail $Stage $Detail
    if ($WithLogs) { Show-Logs }
    throw "VERIFY FAILED at '$Stage'."
}

Write-Host "changedetection.io deployment check"
Write-Host "  image:     $image"
Write-Host "  container: $container   volume: $volume"
if ($WithBrowser) { Write-Host "  browser:   pod $pod, $driverUrl" }

$ok = $false
try {
    Write-Stage '1. Preflight'
    Test-PodmanReady
    & podman image exists $image
    if ($LASTEXITCODE -ne 0) {
        Stop-Verify 'preflight' "image '$image' does not exist.`n        fix: .\contrib\maku.ps1 app build"
    }
    Write-Pass 'preflight'

    Write-Stage '2. Clean slate'
    Remove-Stack @($container, $browser) $pod
    Write-Pass 'clean slate'

    Write-Stage '3. Run'
    if ($WithBrowser) {
        New-AppPod $pod $Port
        Start-BrowserContainer $browser $pod
    }
    if (-not (Start-AppContainer (New-Spec $(if ($WithBrowser) { $pod } else { $null })))) {
        Stop-Verify 'run' "podman run failed. If it is a port conflict, pass -Port with something free."
    }
    Write-Pass 'run'

    Write-Stage "4. Serves $baseUrl (up to ${timeout}s)"
    if (-not (Wait-ForHttp $baseUrl $timeout)) {
        Stop-Verify 'http' "no 200 within ${timeout}s" -WithLogs
    }
    Write-Pass 'http'

    if ($WithBrowser) {
        # Checked from INSIDE the app container, which is the connection that
        # matters. Testing it from the host would prove nothing: port 3000 is
        # pod-internal, and a browser that is running but unreachable is exactly
        # the failure this catches -- the app falls back silently and the Browser
        # Steps UI simply never appears.
        Write-Stage "5. App can reach Chrome on $driverUrl"
        $probe = "python -c `"import socket; socket.create_connection(('localhost', 3000), 5).close()`""
        if (-not (Wait-ForExec $container $probe 15)) {
            Stop-Verify 'browser' "the app container cannot open a connection to localhost:3000" -WithLogs
        }

        # Reachable but unconfigured looks identical from the outside.
        $got = Get-ContainerEnv $container 'PLAYWRIGHT_DRIVER_URL'
        if ($got -ne $driverUrl) {
            Stop-Verify 'browser' "PLAYWRIGHT_DRIVER_URL is '$got', expected '$driverUrl'"
        }

        # A browser nothing is pointed at is a browser nobody uses.
        $backend = Get-ContainerEnv $container 'DEFAULT_FETCH_BACKEND'
        if ($backend -ne 'html_webdriver') {
            Stop-Verify 'browser' "DEFAULT_FETCH_BACKEND is '$backend', expected 'html_webdriver'"
        }
        Write-Pass 'browser'
    }

    # The point of the named volume: rootless Podman maps container root to an
    # unprivileged uid, so a host bind mount would arrive unwritable. This proves
    # the volume is real and outlives the container.
    Write-Stage '6. Data survives the container being destroyed'
    & podman exec $container sh -c "echo persisted-ok > /datastore/.smoketest" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Verify 'persistence' "could not write to /datastore -- check the volume mount" -WithLogs
    }

    # Only the app container is replaced; the browser and pod stay up.
    & podman rm -f $container 2>$null | Out-Null
    if (-not (Start-AppContainer (New-Spec $(if ($WithBrowser) { $pod } else { $null })))) {
        Stop-Verify 'persistence' "container did not come back up after removal"
    }

    # Only the container needs to be running to read the file back, not the whole
    # app, so this waits on exec rather than on HTTP.
    if (-not (Wait-ForExec $container 'cat /datastore/.smoketest' 15)) {
        Stop-Verify 'persistence' "could not read the marker back" -WithLogs
    }
    $marker = (& podman exec $container cat /datastore/.smoketest 2>$null | Out-String).Trim()
    if ($marker -ne 'persisted-ok') {
        Stop-Verify 'persistence' "marker did not survive: got '$marker'" -WithLogs
    }
    & podman exec $container rm -f /datastore/.smoketest 2>$null | Out-Null
    Write-Pass 'persistence'
    $ok = $true
}
finally {
    if ($KeepRunning) {
        Write-Stage 'Teardown (skipped)'
        Write-Host "      $container is still running on $baseUrl"
        Write-Host "      remove it with: .\contrib\maku.ps1 app verify -KeepRunning:`$false, or"
        Write-Host "      podman pod rm -f $pod; podman rm -f $container; podman volume rm $volume"
    } else {
        Remove-Stack @($container, $browser) $pod
        & podman volume rm $volume 2>$null | Out-Null
    }
}

Write-Host ""
$what = if ($WithBrowser) { "ran, served $baseUrl, reached Chrome, and kept its data." }
        else              { "ran, served $baseUrl, and kept its data." }
Write-Host "DEPLOYMENT CHECK PASSED -- $what" -ForegroundColor Green
