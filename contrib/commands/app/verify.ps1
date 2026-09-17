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
    Host port to publish on during the test. Defaults to 5099, NOT the
    deployment's 5000: this check runs on the machine where the real deployment
    lives, and the ordinary sequence there is 'app update' then 'app verify'.
    Sharing the port makes that sequence fail every time.

.PARAMETER KeepRunning
    Leave it up afterwards for the manual checks in contrib/podman/VERIFY.md.

.EXAMPLE
    .\contrib\maku.ps1 app verify -WithBrowser
#>
param(
    [switch]$WithBrowser,
    [string]$Image,
    [int]$Port = 5099,
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

# A pass-or-fail question for the container. No answer AT ALL is its own kind of
# failure and gets its own sentence: it means python never reached the print, so
# comparing what came back against the expected value would be reporting a
# broken measurement as a property of the image.
function Get-RuntimeValue([string]$Setup, [string]$Expression) {
    $result = Get-ContainerPythonValue $container $Setup $Expression
    if ($null -eq $result.Value) {
        Stop-Verify 'runtime' ("python in the container did not answer. It said:" +
                               [Environment]::NewLine + $result.Output)
    }
    return $result.Value
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
    # Before anything is created, because nothing created later will name it.
    # -WithBrowser publishes through the POD, and a pod's port is bound by its
    # infra container when the FIRST container starts -- so a taken port aborts
    # the browser run with 'internal libpod error' (exit 126) and says nothing
    # about ports at all. That is what this turns into a sentence.
    if (Test-PortInUse $Port) {
        Stop-Verify 'preflight' ("something is already serving 127.0.0.1:$Port -- most likely the real" + [Environment]::NewLine +
                                 "        deployment. This check must not share a port with it." + [Environment]::NewLine +
                                 "        fix: drop -Port to use the default 5099, or pass one that is free")
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

    # The fork changes upstream BEHAVIOUR without patching an upstream file: a
    # read-only mount of contrib/runtime plus PYTHONPATH, so python imports
    # sitecustomize automatically and it patches the app after import. Nothing in
    # the UI shows whether that arrived -- an absent mount looks exactly like a
    # stock container -- so it is asserted here or not at all.
    Write-Stage '5. Fork runtime patches are live'

    & podman exec $container test -f /maku-runtime/sitecustomize.py 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Verify 'runtime' ("/maku-runtime/sitecustomize.py is not in the container -- the mount did not arrive.`n" +
                               "        On the WSL backend podman does not translate every Windows path.")
    }

    # Present is not the same as FOUND. This is the check that PYTHONPATH is set
    # and that /usr/local was prepended to rather than replaced.
    $resolved = Get-RuntimeValue 'import sitecustomize' 'sitecustomize.__file__'
    if ($resolved -ne '/maku-runtime/sitecustomize.py') {
        Stop-Verify 'runtime' "python resolves sitecustomize to '$resolved', expected /maku-runtime/sitecustomize.py"
    }

    # And FOUND is not the same as CORRECT.
    $formatted = Get-RuntimeValue 'import sitecustomize' 'sitecustomize.format_number_locale(3.3715)'
    if ($formatted -notin @('3.3715', '3,3715')) {
        Stop-Verify 'runtime' "the replacement filter returned '$formatted' for 3.3715 -- expected the precision to be kept"
    }
    Write-Pass 'runtime' "sitecustomize loaded, 3.3715 keeps 4 dp"

    # The strongest check available, and the only one that exercises the real
    # module rather than the dummy in contrib/runtime/test_hook.py: import
    # flask_app and read the filter off the live Jinja environment.
    #
    # Best effort BY DESIGN, so it does NOT go through Get-RuntimeValue.
    # Importing flask_app standalone builds the whole Flask app, which may need
    # arguments or env this throwaway container does not have. A failure here
    # means "not proven", not "broken", and saying so is better than either
    # failing the run or quietly claiming success.
    #
    # That is also exactly why it has to be honest about WHICH it is. This check
    # once read its own captured output wrong -- the app's loguru lines go to
    # stderr, they were folded into the compared string, and the warning below
    # printed on a run where the hook had in fact fired. Doubt is expensive here:
    # it is cast on the one thing no other check can reach.
    $live = Get-ContainerPythonValue $container 'import changedetectionio.flask_app as f' `
                                     "f.app.jinja_env.filters['format_number_locale'].__module__"
    if ($live.Value -eq 'sitecustomize') {
        Write-Pass 'runtime' 'the hook fired against the real flask_app'
    } else {
        $said = if ($null -eq $live.Value) { $live.Output } else { "'$($live.Value)'" }
        Write-Warn 'runtime' "could not confirm the hook against the real flask_app."
        Write-Host "      Not a failure: the checks above prove the module loads and behaves."
        Write-Host "      What is unproven is only that it patched THIS app's live Jinja env."
        Write-Host "      python said: $said"
    }

    # The second runtime patch, in the same two steps and for the same reason.
    # That the module loads from the mount and answers correctly is provable
    # outright; that it reached the application's OWN fetcher class is the part
    # nothing else can see, and is therefore best effort rather than fatal.
    $validator = Get-RuntimeValue 'import maku_conditional_fetch as m' `
                                  'm.pick_validators({"etag": "abc"}).get("If-None-Match")'
    if ($validator -ne 'abc') {
        Stop-Verify 'runtime' ("maku_conditional_fetch turned an ETag of abc into '$validator' -- " +
                               "expected it back verbatim as If-None-Match.")
    }
    Write-Pass 'runtime' 'conditional-fetch module loaded'

    $wrapped = Get-ContainerPythonValue $container 'import changedetectionio.content_fetchers.requests as r' `
                                        "getattr(r.fetcher._run_sync, '_maku_conditional', False)"
    if ($wrapped.Value -eq 'True') {
        Write-Pass 'runtime' 'the plain fetcher revalidates before downloading'
    } else {
        $said = if ($null -eq $wrapped.Value) { $wrapped.Output } else { "'$($wrapped.Value)'" }
        Write-Warn 'runtime' 'could not confirm the conditional-fetch patch on the live fetcher.'
        Write-Host "      Not a failure, and nothing is broken if it is absent: an unpatched"
        Write-Host "      fetcher simply downloads every page, exactly as upstream does."
        Write-Host "      python said: $said"
    }

    if ($WithBrowser) {
        # Checked from INSIDE the app container, which is the connection that
        # matters. Testing it from the host would prove nothing: port 3000 is
        # pod-internal, and a browser that is running but unreachable is exactly
        # the failure this catches -- the app falls back silently and the Browser
        # Steps UI simply never appears.
        Write-Stage "6. App can reach Chrome on $driverUrl"
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
    Write-Stage '7. Data survives the container being destroyed'
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
