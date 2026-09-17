# Every podman invocation this project makes.
#
# WHY THIS EXISTS. The container start-up arguments used to be written out five
# times for the app and three times for the browser, and they had already
# drifted: one copy omitted SCREEN_DEPTH, another omitted
# MAX_CONCURRENT_CHROME_PROCESSES, so the smoke test and the real deployment were
# not running the same browser. One definition each, here.

Import-Module (Join-Path $PSScriptRoot 'Images.psm1')
Import-Module (Join-Path $PSScriptRoot 'Console.psm1')

$script:AppContainer     = 'changedetection'
$script:BrowserContainer = 'browser-sockpuppet-chrome'
$script:Pod              = 'changedetection-pod'
$script:Volume           = 'changedetection-data'

function Get-PodmanNames {
    return [pscustomobject]@{
        App     = $script:AppContainer
        Browser = $script:BrowserContainer
        Pod     = $script:Pod
        Volume  = $script:Volume
    }
}

function Test-PodmanReady {
    # Get-Command first: an ABSENT executable raises CommandNotFoundException,
    # which $ErrorActionPreference='Stop' turns into a terminating error before
    # any exit code can be inspected -- so the reader would get PowerShell's
    # "term is not recognized" instead of a sentence telling them what to install.
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        throw ("podman is not installed, or not on PATH." + [Environment]::NewLine +
               "  fix: see contrib/podman/VERIFY.md -- Prerequisites")
    }
    & podman --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "podman is installed but did not run. See contrib/podman/VERIFY.md."
    }
    Assert-PodmanResponds
}

# 'podman info' is the first call that crosses into the machine, so it is where a
# running-but-unreachable VM surfaces. Its stderr is the only thing that says
# WHICH: a stopped machine, a connection pointing at one that no longer exists,
# and an elevated shell looking at a different rootless socket all fail here and
# are indistinguishable once the message is thrown away.
#
# An earlier version threw it away and asserted "the machine is probably not
# running". That is a guess formatted as a diagnosis, and its fix line sends the
# reader to run `podman machine start` -- which, when the machine IS running,
# answers "already running" and leaves them with nothing to go on.
function Assert-PodmanResponds {
    $detail = (& podman info 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { return }
    throw (New-Refusal "podman info failed (exit $LASTEXITCODE). podman said:`n$detail" `
                       "podman machine list  --  and if it is running: podman system connection list")
}

# The commit a built image came from is stamped ON the image, because it is the
# only place that survives. A deployment machine can pull, fail, be rebooted and
# run again a week later; nothing outside the image remembers which source it was
# built from, and asking git alone can only ever answer what MOVED, never what
# was actually built. 'app update' reads this back to decide.
$script:RevisionLabel = 'org.opencontainers.image.revision'

function Build-Image([string]$Image, [switch]$NoCache) {
    $root = (& git rev-parse --show-toplevel).Trim()
    $head = (& git rev-parse HEAD).Trim()
    $podmanArgs = @('build', '-t', $Image, '-f', (Join-Path $root 'Dockerfile'),
                    '--label', "$script:RevisionLabel=$head")
    # Fallback for an older Buildah that mishandles the Dockerfile's
    # RUN --mount=type=cache directives.
    if ($NoCache) { $podmanArgs += '--no-cache' }
    $podmanArgs += $root

    Write-Host "podman $($podmanArgs -join ' ')"
    Write-BuildWaitNotice
    $started = Get-Date

    # Out-Host, not a bare call. podman writes its STEP lines to stderr, which
    # streams, but the final image ID to STDOUT -- and a caller writing
    # `$image = Build-Image ...` captures that into the return value. It did:
    # $image came back as TWO elements, so 'OK build' printed
    # "sha256:deadbeef... changedetection.io:dev". Sending it to the host keeps
    # it on screen and out of the pipeline. This function now returns nothing;
    # the caller already knows the name, it passed it in.
    & podman @podmanArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "podman build failed (exit $LASTEXITCODE). On an older Buildah, retry with -NoCache."
    }
    Write-Host ("Build finished in " + ((Get-Date) - $started).ToString('hh\:mm\:ss') + ".")
}

# A full application build takes minutes and podman says NOTHING during the
# longest of them: the base image pull and the pip install behind
# RUN --mount=type=cache both run silently to completion. Every report of this
# command "freezing" has been that silence. Saying so up front costs one line
# and is the difference between waiting and killing a working build.
function Write-BuildWaitNotice {
    Write-Host "Building the application image. Several minutes is normal, and longer on"
    Write-Host "the first build after a version bump -- podman prints nothing at all while"
    Write-Host "it pulls the base image and installs requirements. It has not hung."
    Write-Host "To confirm from another terminal:  podman ps -a --external"
}

# The commit an existing image was built from, or $null when there is no such
# image, podman cannot be reached, or the image predates the label. All three
# mean the same thing to a caller -- this image cannot be shown to be current --
# and the right response to every one of them is to rebuild, not to assume.
function Get-ImageRevision([string]$Image) {
    # '{{json .Labels}}', not '{{index .Labels "<key>"}}'. The key contains dots
    # so it cannot be a template field, and the index form puts double quotes
    # INSIDE an argument that PowerShell then re-quotes for a Windows command
    # line -- a round trip that is quietly host-specific. The whole map as JSON
    # needs no quoting at all and PowerShell indexes it directly.
    $json = & podman image inspect $Image --format '{{json .Labels}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $key    = $script:RevisionLabel
    $labels = ($json | Out-String).Trim() | ConvertFrom-Json -ErrorAction SilentlyContinue
    $sha    = if ($labels) { $labels.$key } else { $null }
    if ($sha -notmatch '^[0-9a-f]{40}$') { return $null }
    return $sha
}

# Clears BOTH topologies, always. A previous run may have left either behind,
# and both publish the port: a plain run through the container, -WithBrowser
# through the POD's infra container, which keeps the binding even after the app
# container is gone. Removing only one leaves the next start dying with
# "address already in use" (exit 126).
#
# The named volume -- every watch and its history -- is untouched by any of it.
function Remove-Stack([string[]]$Containers, [string]$Pod) {
    if ($Containers) { & podman rm -f @Containers 2>$null | Out-Null }
    if ($Pod)        { & podman pod rm -f $Pod     2>$null | Out-Null }
}

# The pod owns the published port; containers inside must not publish their own.
function New-AppPod([string]$Name, [int]$Port) {
    & podman pod create --name $Name -p "127.0.0.1:${Port}:5000" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "podman pod create failed (exit $LASTEXITCODE)." }
}

# Chrome, wrapped in an API. --shm-size=2g because podman defaults /dev/shm to
# 64MB and Chrome dies with "Target closed" / renderer failures well before that
# is genuinely exhausted.
function Start-BrowserContainer([string]$Name, [string]$Pod) {
    $podmanArgs = @('run', '-d', '--name', $Name)
    if ($Pod) { $podmanArgs += @('--pod', $Pod) }
    $podmanArgs += @(
        '--restart', 'unless-stopped'
        '--shm-size=2g'
        '--cap-add', 'SYS_ADMIN'
        '-e', 'SCREEN_WIDTH=1920'
        '-e', 'SCREEN_HEIGHT=1024'
        '-e', 'SCREEN_DEPTH=16'
        '-e', 'MAX_CONCURRENT_CHROME_PROCESSES=10'
        (Get-ImagePin 'Browser')
    )
    & podman @podmanArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "podman run (browser) failed (exit $LASTEXITCODE)." }
}

# Spec keys: Name, Image, Volume, Port, Pod, DriverUrl, Restart.
# A single hashtable rather than seven parameters -- the caller reads as a
# declaration of what it wants, and the signature stays within the limit.
function Start-AppContainer([hashtable]$Spec) {
    $port = $Spec.Port
    $podmanArgs = @('run', '-d', '--name', $Spec.Name)

    if ($Spec.Pod) {
        # In a pod the published port belongs to the pod, not to this container.
        $podmanArgs += @('--pod', $Spec.Pod)
    } else {
        $podmanArgs += @('-p', "127.0.0.1:${port}:5000")
    }
    if ($Spec.Restart) { $podmanArgs += @('--restart', 'unless-stopped') }

    $podmanArgs += @('-v', "$($Spec.Volume):/datastore", '-e', "BASE_URL=http://localhost:$port")

    if ($Spec.DriverUrl) {
        # DEFAULT_FETCH_BACKEND makes NEW watches use Chrome. Without it the
        # browser runs but nothing points at it: every watch keeps fetching plain
        # HTML until Fetch Method is changed by hand, one watch at a time. It
        # seeds the settings DEFAULT, so it takes effect on a FRESH datastore --
        # an existing install keeps its saved value.
        $podmanArgs += @('-e', "PLAYWRIGHT_DRIVER_URL=$($Spec.DriverUrl)"
                   '-e', 'DEFAULT_FETCH_BACKEND=html_webdriver')
    }
    $podmanArgs += $Spec.Image

    & podman @podmanArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    return $true
}

# A listening port is not enough on first start -- the app does one-time setup
# before it serves, so this polls rather than checking once.
function Wait-ForHttp([string]$Url, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            if ((Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) {
                return $true
            }
        } catch {
            # Not up yet. Keep waiting until the deadline.
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Runs a command inside a container until it succeeds or the tries run out.
function Wait-ForExec([string]$Container, [string]$Command, [int]$Tries) {
    for ($i = 0; $i -lt $Tries; $i++) {
        & podman exec $Container sh -c $Command 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Reads an environment variable from inside a running container. Used to prove
# the app was actually TOLD about the browser -- reachable but unconfigured looks
# identical from the outside.
function Get-ContainerEnv([string]$Container, [string]$Name) {
    $value = & podman exec $Container sh -c "echo `$$Name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($value | Out-String).Trim()
}

Export-ModuleMember -Function Get-PodmanNames, Test-PodmanReady, Build-Image, Remove-Stack,
                              Get-ImageRevision,
                              New-AppPod, Start-BrowserContainer, Start-AppContainer,
                              Wait-ForHttp, Wait-ForExec, Get-ContainerEnv
