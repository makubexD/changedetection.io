# Run the project's own pytest suite under Podman, including the tests that
# need a real Chrome.
#
#   .\contrib\podman\test-suite.ps1                  # price + restock (the default)
#   .\contrib\podman\test-suite.ps1 -Suite unit      # fast, no browser
#   .\contrib\podman\test-suite.ps1 -Suite browser   # everything browser-backed
#   .\contrib\podman\test-suite.ps1 -Suite all       # the lot; slow
#   .\contrib\podman\test-suite.ps1 -Path tests/test_restock_itemprop.py::test_itemprop_price_change
#
# WHY THIS EXISTS. The tests that matter here -- price extraction from ld+json,
# through a real browser -- already exist in changedetectionio/tests/ and need a
# browser to run. Without this you either need Docker, or you push and wait for
# CI. This gets the same answer locally in one command.
#
# It serves its fixture pages from a live server INSIDE the pod, so nothing
# reaches the public internet: no site can block it, nothing is flaky because a
# retailer changed a page, and the results mean the same thing every run.
#
# DIFFERENT FROM test.ps1, which smoke-tests a DEPLOYMENT (build, run, answer on
# :5000, keep its data). This runs the application's unit and integration tests.
#
# YOUR DATA IS SAFE. Every name here is prefixed cdio-suite and the pod is
# removed at the end, so it can never touch a real `changedetection` deployment.
param(
    [ValidateSet('price', 'unit', 'browser', 'all')]
    [string]$Suite = 'price',
    # Run exactly this instead of a named suite. A path, or a pytest node id.
    [string]$Path,
    [string]$Tag = 'suite',
    # Reuse the image from the last run instead of rebuilding.
    [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'

# Cleanup below is expected to fail when there is nothing to remove, and
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error.
# Exit codes are checked by hand where they matter. Same guard as run.ps1.
if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Resolve-Path "$PSScriptRoot\..\.."
$image    = "cdio-test:$Tag"
$podName  = 'cdio-suite-pod'
$browser  = 'cdio-suite-browser'
$runner   = 'cdio-suite-runner'

# Pinned by digest, not :latest -- that tag is rebuilt often and bakes in
# whatever Chrome Stable is current on build day, which silently changes the
# browser under your tests. Same pin as the other files here.
$browserImage = 'docker.io/dgtlmoon/sockpuppetbrowser@sha256:a61e64a694fef3b6d375a3c7c7dd7d74b1166a48b231cd98870b78f244deef79'

# Which files each name runs, and whether Chrome has to be up for them.
# Taken from what upstream's own CI runs, so a green run here means the same
# thing a green run there would.
$SUITES = @{
    price   = @{ browser = $true;  paths = @(
        'tests/test_restock_itemprop.py'
        'tests/test_automatic_follow_ldjson_price.py'
        'tests/restock/test_restock.py') }
    unit    = @{ browser = $false; paths = @('tests/unit/', 'tests/llm/') }
    browser = @{ browser = $true;  paths = @(
        'tests/restock/test_restock.py'
        'tests/visualselector/test_fetch_data.py'
        'tests/fetchers/test_content.py') }
    all     = @{ browser = $true;  paths = @('tests/') }
}

$logDir = Join-Path $PSScriptRoot 'test-logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $(if ($Path) { 'custom' } else { $Suite }))

function Remove-Leftovers {
    foreach ($c in $runner, $browser) { & podman rm -f $c 2>$null | Out-Null }
    & podman pod rm -f $podName 2>$null | Out-Null
}

function Build-Image {
    if ($NoBuild) {
        & podman image exists $image
        if ($LASTEXITCODE -ne 0) { throw "-NoBuild was passed but $image does not exist yet." }
        Write-Host "Reusing $image"
        return
    }
    Write-Host "Building $image ..."
    & podman build -t $image -f "$repoRoot\Dockerfile" $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "podman build failed with exit code $LASTEXITCODE" }
}

# One pod, so the runner and Chrome share a network namespace and reach each
# other on localhost. That is also why the fixture server binds 0.0.0.0: Chrome
# fetches the test's own pages back over localhost.
function Start-Browser {
    & podman pod create --name $podName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not create pod $podName" }
    & podman run -d --pod $podName --name $browser --shm-size=2g --cap-add=SYS_ADMIN `
        -e SCREEN_WIDTH=1920 -e SCREEN_HEIGHT=1024 -e SCREEN_DEPTH=16 `
        $browserImage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not start the browser container" }

    foreach ($i in 1..30) {
        & podman exec $browser sh -c "true" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "browser container never became ready"
}

function Get-PytestArgs {
    $paths = if ($Path) { @($Path) } else { $SUITES[$Suite].paths }
    return @('-vv', '--capture=tee-sys', '--tb=short',
             '--live-server-host=0.0.0.0', '--live-server-port=5004') + $paths
}

function Invoke-Suite([bool]$withBrowser) {
    $env_args = @('-e', 'LOGGER_LEVEL=TRACE')
    $podArgs  = @()
    if ($withBrowser) {
        $podArgs = @('--pod', $podName)
        $env_args += @('-e', 'PLAYWRIGHT_DRIVER_URL=ws://localhost:3000',
                       '-e', 'FLASK_SERVER_NAME=localhost')
    }
    $pytest = (Get-PytestArgs) -join ' '
    Write-Host "pytest $pytest"
    Write-Host ""
    & podman run --rm --name $runner @podArgs @env_args $image `
        bash -c "cd changedetectionio; pytest $pytest" 2>&1 | Tee-Object -FilePath $logFile
    return $LASTEXITCODE
}

# pytest's own last line is the only trustworthy summary; anything reconstructed
# from the output would drift from it.
function Show-Summary([int]$code) {
    $tail = Get-Content $logFile -Tail 12 | Where-Object { $_ -match '=====' -or $_ -match 'passed|failed|error' }
    Write-Host ""
    Write-Host "---------------------------------------------------------------"
    if ($tail) { $tail | Select-Object -Last 1 | ForEach-Object { Write-Host $_ } }
    Write-Host "Full output: $logFile"
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "Failures, in order, with the assertion that broke:"
        Select-String -Path $logFile -Pattern '^(FAILED|ERROR) ' | ForEach-Object { Write-Host "  $($_.Line)" }
    }
    Write-Host "---------------------------------------------------------------"
}

$needsBrowser = if ($Path) { $true } else { $SUITES[$Suite].browser }

Remove-Leftovers
try {
    Build-Image
    if ($needsBrowser) {
        Write-Host "Starting Chrome (ws://localhost:3000 inside the pod) ..."
        Start-Browser
    }
    $code = Invoke-Suite $needsBrowser
    Show-Summary $code
    if ($code -ne 0) { exit $code }
    Write-Host "PASSED"
} finally {
    Remove-Leftovers
}
