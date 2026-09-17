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
               "  fix: install it -- contrib/fork/SETUP.md step 1")
    }
    & podman --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Names the command rather than a document. A reader who has to go and
        # look something up is one step further from running again than a reader
        # who can paste the next line.
        throw ("podman is installed but did not run." + [Environment]::NewLine +
               "  fix: podman machine start")
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
    # @() around each call, and NOTHING returned. A function that emits nothing
    # still assigns $null through '+=', which would put a blank in the record;
    # and returning the list would put it on the pipeline, where every caller
    # runs at a script's top level and it would simply print itself.
    $removed = @()
    foreach ($c in @($Containers | Where-Object { $_ })) {
        $removed += @(Remove-PodmanObject @('rm', '-f', $c) $c)
    }
    if ($Pod) { $removed += @(Remove-PodmanObject @('pod', 'rm', '-f', $Pod) "pod $Pod") }
    if ($removed) { Add-Action 'removed' ($removed -join ', ') }
}

# One removal, with "there was nothing there" told apart from "it would not go".
#
# THE OLD FORM DISCARDED BOTH. `2>$null | Out-Null` with no exit check meant a
# pod that failed to die was indistinguishable from one that never existed --
# and a pod that survives keeps the published port, so the failure resurfaced
# minutes later as a port refusal with no way back to this line.
function Remove-PodmanObject([string[]]$PodmanArgs, [string]$Label) {
    $out = (& podman @PodmanArgs 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        # `podman rm -f` exits 0 for something that was not there, printing
        # nothing, and echoes the id only when it actually removed one. That is
        # the whole signal separating "cleaned up" from "nothing to clean up".
        return $(if ($out) { @($Label) } else { @() })
    }
    # Older podman reports the absent case as an error instead. Same meaning.
    if ($out -match 'no such|no pod with name|not exist') { return @() }
    throw ("could not remove $Label." + [Environment]::NewLine +
           "  podman said: $out" + [Environment]::NewLine +
           "  fix: podman ps -a ; podman pod ps")
}

# Is something already serving this port on the host?
#
# ASK BEFORE CREATING THE POD, because the pod itself will not tell you. Creating
# one binds nothing; its INFRA container binds when the first container starts,
# so a taken port surfaces as a failure to run whatever that first container
# happened to be -- 'Error: starting some containers: internal libpod error',
# exit 126, with no mention of a port anywhere in it. The plain -p topology at
# least says "address already in use".
#
# A connect, not a bind test: the question is whether something is SERVING here,
# which is both the cause of the bind failure and the thing worth naming in the
# message. On loopback a refusal comes back immediately.
function Test-PortInUse([int]$Port) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try     { $client.Connect('127.0.0.1', $Port); return $true }
    catch   { return $false }
    finally { $client.Dispose() }
}

# Waits for a port WE JUST RELEASED to actually go quiet.
#
# Teardown is not instantaneous. On Windows podman's host-side forwarder closes
# its listener a moment AFTER 'podman pod rm -f' has returned, so a connect test
# still succeeds against a pod that is already gone. The everyday restart is the
# one path that frees this port and asks for it back in the same breath, so it
# is the one path guaranteed to race -- and refusing there was refusing the
# ordinary case, which is the worst possible place to be strict.
#
# A genuine squatter never goes quiet, so this still fails, just later.
function Wait-ForPortFree([int]$Port, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PortInUse $Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    # Asked once more after the deadline, so a timeout of 0 still answers the
    # question rather than always answering "no".
    return -not (Test-PortInUse $Port)
}

# Which podman container publishes this port, or $null when podman does not own
# it at all.
#
# Worth asking before refusing, because 'podman ps' CANNOT show a process podman
# did not start -- so a refusal whose only suggestion is 'podman ps -a' sends the
# reader to an empty list in exactly the case where they most need a next step.
#
# --all and --external: a -WithBrowser deployment publishes through the POD, and
# the binding belongs to its infra container, which a plain 'podman ps' hides.
function Get-PortHolder([int]$Port) {
    $rows = & podman ps --all --external --format '{{.Names}} {{.Ports}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($row in @($rows)) {
        if ($row -match ":$Port->") { return $row.Trim() }
    }
    return $null
}

# The id of an image by name, or $null when there is no such image locally.
# 'app update' compares this against the image a running container was started
# from, which is the only comparison that survives a rebuild under the same tag.
function Get-ImageId([string]$Image) {
    $id = & podman image inspect $Image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($id | Out-String).Trim()
}

# What the running deployment actually IS, so a caller can compare it against
# what was asked for. $null when there is no such container -- podman reports
# that as an error rather than an empty result.
#
# ONE template, no quotes inside it, following Get-ImageRevision above: the
# '{{index . "key"}}' form puts double quotes inside an argument that PowerShell
# then re-quotes for a Windows command line, and that round trip is host-specific.
# Env goes last so the three fixed fields keep their positions however many
# variables the container carries.
#
# Only fields this file's callers actually read. A template naming one podman
# does not have fails the whole call, and the caller would read that as "no such
# container" and restart a deployment that was fine.
function Get-ContainerState([string]$Name) {
    $fmt  = '{{.Image}}|{{.State.Status}}|{{.State.StartedAt}}{{range .Config.Env}}|{{.}}{{end}}'
    $line = & podman container inspect $Name --format $fmt 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $parts = @(($line | Out-String).Trim() -split '\|')
    if ($parts.Count -lt 3) { return $null }
    return [pscustomobject]@{
        Image     = $parts[0]
        Status    = $parts[1]
        StartedAt = ConvertFrom-PodmanTime $parts[2]
        Env       = ConvertTo-EnvMap @($parts | Select-Object -Skip 3)
    }
}

# podman stamps times with NANOSECOND precision and .NET parses at most seven
# fractional digits, failing outright on nine. UTC, because the only thing this
# is ever compared against is a file's LastWriteTimeUtc.
function ConvertFrom-PodmanTime([string]$Text) {
    $stamp  = $Text -replace '(\.\d{1,7})\d*', '$1'
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($stamp, [ref]$parsed)) { return [datetime]::MinValue }
    return $parsed.ToUniversalTime()
}

# 'KEY=value' entries to a lookup. Split on the FIRST '=' only: values routinely
# contain more of them, and BASE_URL is read back from here.
function ConvertTo-EnvMap([string[]]$Entries) {
    $map = @{}
    foreach ($e in $Entries) {
        $i = $e.IndexOf('=')
        if ($i -gt 0) { $map[$e.Substring(0, $i)] = $e.Substring($i + 1) }
    }
    return $map
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

# contrib/runtime holds the fork's runtime patches and the probe script, and the
# container cannot see them any other way: the Dockerfile copies the application
# paths and nothing else, so everything under contrib/ is absent from the image.
# A read-only mount plus PYTHONPATH is the whole installation.
#
# PREPENDED to /usr/local, never replacing it. The image already sets
# ENV PYTHONPATH=/usr/local (Dockerfile:140) and overwriting that breaks imports
# the application needs.
#
# This is the mechanism that keeps the fork's ONE patched upstream file at one.
# A runtime override lives in a file upstream does not have, so it can never
# conflict with a merge, and pulling the mount returns the container to stock.
function Get-RuntimeMountArgs {
    $runtime = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime'
    if (-not (Test-Path (Join-Path $runtime 'sitecustomize.py'))) { return @() }
    # Forward slashes: podman's Windows client parses a drive-letter path more
    # reliably this way, and the ':ro' suffix is unambiguous against 'C:'.
    $mount = $runtime.Replace('\', '/')
    return @('-v', "${mount}:/maku-runtime:ro", '-e', 'PYTHONPATH=/maku-runtime:/usr/local')
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
    $podmanArgs += Get-RuntimeMountArgs

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

$script:ValueMarker = 'MAKU_VALUE='

# The value a one-liner PRINTED, picked out of everything else the container
# wrote. $null when the marked line never appeared at all -- which means python
# did not reach the print, and is a different fact from "it printed the wrong
# thing".
#
# A MARKED LINE, not "take the last one". Through a pipe stdout is block
# buffered and stderr is not, so which of the two lands last is an accident of
# flushing rather than something to build a check on.
function Select-PythonValue([string]$Text) {
    foreach ($line in ($Text -split "`n")) {
        if ($line.StartsWith($script:ValueMarker)) {
            return $line.Substring($script:ValueMarker.Length).Trim()
        }
    }
    return $null
}

# Ask a running container one question, and get back an answer the container's
# own logging cannot corrupt.
#
# STDERR IS STILL CAPTURED, deliberately. When the import genuinely fails, the
# traceback there is the only thing that says why, and the caller has nothing
# else to put in its message. It simply must not be part of the ANSWER -- and it
# was: eleven loguru lines from 'import changedetectionio.flask_app' landed
# inside the string a verify check compared, so a check that had PASSED reported
# that it could not confirm the fork's patch.
#
# LOGURU_LEVEL is for that failure path, not for the comparison. The marker
# already makes the value immune to whatever else gets printed; this only keeps
# the diagnostic readable when there is one to read.
#
# -w /app for every caller: with 'python -c', sys.path[0] is the working
# directory, so importing the application needs it and nothing else is harmed.
function Get-ContainerPythonValue([string]$Container, [string]$Setup, [string]$Expression) {
    $code   = "$Setup; print('$script:ValueMarker' + str($Expression))"
    $output = (& podman exec -e LOGURU_LEVEL=WARNING -w /app $Container python -c $code 2>&1 | Out-String)
    return [pscustomobject]@{ Value = (Select-PythonValue $output); Output = $output.Trim() }
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
                              Get-ImageRevision, Get-ImageId, Get-RuntimeMountArgs,
                              Test-PortInUse, Wait-ForPortFree, Get-PortHolder,
                              Get-ContainerState,
                              New-AppPod, Start-BrowserContainer, Start-AppContainer,
                              Wait-ForHttp, Wait-ForExec, Get-ContainerEnv,
                              Select-PythonValue, Get-ContainerPythonValue
