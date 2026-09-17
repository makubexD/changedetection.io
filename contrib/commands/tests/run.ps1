#: run the project's own pytest suite, browser included

<#
.SYNOPSIS
    Run changedetection.io's own tests under Podman, including those needing Chrome.

.DESCRIPTION
    WHY THIS EXISTS. The tests that matter here -- price extraction from ld+json,
    through a real browser -- already exist in changedetectionio/tests/ and need a
    browser to run. Without this you either need Docker, or you push and wait for
    CI. This gets the same answer locally in one command.

    Fixture pages are served by a live server INSIDE the pod, so nothing reaches
    the public internet: no site can block it, nothing is flaky because a retailer
    changed a page, and a result means the same thing every run.

    That is also its limit: it tells you the CODE works. Whether a particular shop
    will answer YOUR connection is a different question, and only a real watch on
    this machine answers it.

    DIFFERENT FROM 'app verify', which checks a DEPLOYMENT -- that it runs, serves
    and keeps its data. This runs the application's own tests.

.PARAMETER Suite
    price   itemprop + ld+json + restock, through Chrome  (the default)
    unit    tests/unit and tests/llm -- fast, no browser
    browser restock, visual selector, fetchers -- all browser-backed
    all     everything; slow

.PARAMETER Path
    Run exactly this instead of a named suite. A path, or a pytest node id.

.PARAMETER NoBuild
    Reuse the image from the last run. A change to application code will NOT be
    picked up -- drop this whenever you have edited changedetectionio/.

.EXAMPLE
    .\contrib\maku.ps1 tests run -Suite unit
.EXAMPLE
    .\contrib\maku.ps1 tests run -Path tests/test_restock_itemprop.py::test_itemprop_price_change
#>
param(
    [ValidateSet('price', 'unit', 'browser', 'all')]
    [string]$Suite = 'price',
    [string]$Path,
    [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

$repoRoot = Get-RepoRoot
$image    = 'cdio-test:suite'
$pod      = 'cdio-suite-pod'
$browser  = 'cdio-suite-browser'
$runner   = 'cdio-suite-runner'

# Which files each name runs, and whether Chrome has to be up for them. Taken
# from what upstream's own CI runs, so a green run here means what a green run
# there would.
$suites = @{
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

$logDir = Join-Path $repoRoot 'contrib/podman/test-logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $(if ($Path) { 'custom' } else { $Suite }))

# A custom -Path could be any test, so assume it needs the browser.
$needsBrowser = if ($Path) { $true } else { $suites[$Suite].browser }
$paths        = if ($Path) { @($Path) } else { $suites[$Suite].paths }

# pytest's own last line is the only trustworthy summary; anything reconstructed
# from the output would drift from what pytest actually concluded.
function Show-Summary([int]$code) {
    $tail = Get-Content $logFile -Tail 12 |
            Where-Object { $_ -match '=====' -or $_ -match 'passed|failed|error' }
    Write-Host ""
    Write-Host "---------------------------------------------------------------"
    if ($tail) { $tail | Select-Object -Last 1 | ForEach-Object { Write-Host $_ } }
    Write-Host "Full output: $logFile"
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "Failures, in order, with the assertion that broke:"
        Select-String -Path $logFile -Pattern '^(FAILED|ERROR) ' |
            ForEach-Object { Write-Host "  $($_.Line)" }
    }
    Write-Host "---------------------------------------------------------------"
}

Test-PodmanReady
Remove-Stack @($runner, $browser) $pod
try {
    if ($NoBuild) {
        & podman image exists $image
        if ($LASTEXITCODE -ne 0) {
            throw "-NoBuild was passed but $image does not exist yet. Run once without it."
        }
        Write-Host "Reusing $image"
    } else {
        Build-Image $image
    }

    if ($needsBrowser) {
        Write-Host "Starting Chrome (ws://localhost:3000 inside the pod) ..."
        & podman pod create --name $pod | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not create pod $pod" }
        Start-BrowserContainer $browser $pod
        if (-not (Wait-ForExec $browser 'true' 30)) { throw "browser container never became ready" }
    }

    # --live-server-host=0.0.0.0 so Chrome, in the other container, can fetch the
    # test's own fixture pages back over the pod's shared localhost.
    $pytestArgs = @('-vv', '--capture=tee-sys', '--tb=short',
                    '--live-server-host=0.0.0.0', '--live-server-port=5004') + $paths
    $podArgs = @()
    $envArgs = @('-e', 'LOGGER_LEVEL=TRACE')
    if ($needsBrowser) {
        $podArgs = @('--pod', $pod)
        $envArgs += @('-e', 'PLAYWRIGHT_DRIVER_URL=ws://localhost:3000',
                      '-e', 'FLASK_SERVER_NAME=localhost')
    }

    Write-Host "pytest $($pytestArgs -join ' ')"
    Write-Host ""
    & podman run --rm --name $runner @podArgs @envArgs $image `
        bash -c "cd changedetectionio; pytest $($pytestArgs -join ' ')" 2>&1 |
        Tee-Object -FilePath $logFile
    $code = $LASTEXITCODE

    Show-Summary $code
    if ($code -ne 0) { exit $code }
    Write-Pass 'tests' $(if ($Path) { $Path } else { "suite '$Suite'" })
}
finally {
    Remove-Stack @($runner, $browser) $pod
}
