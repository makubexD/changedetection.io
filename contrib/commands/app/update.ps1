#: pull new code, rebuild only if needed, and restart

<#
.SYNOPSIS
    Bring a deployment machine up to the latest code in one command.

.DESCRIPTION
    Pulls the branch you already have checked out and fast-forwards it. It never
    merges, never switches branch and never pushes, so it is safe on a machine
    that only deploys.

    Bringing new UPSTREAM commits into the release branch is a different job with
    different failure modes -- a merge, a CI gate, a push -- and lives in
    'fork sync', on the machine where the work happens. Run that there, then run
    this here.

    YOUR DATA IS SAFE. 'app start' does the actual start and replaces the
    container, never the volume.

.PARAMETER WithBrowser
    Passed straight through to 'app start'.

.PARAMETER Image
    Deploy a published image instead of building. Nothing is built and the
    rebuild check is skipped entirely.

.PARAMETER Port
    Passed straight through to 'app start'.

.PARAMETER Force
    Restart even when the running deployment already matches. Nothing else is
    affected -- the pull and the rebuild check make their own decisions and are
    not overridden by this.

.EXAMPLE
    .\contrib\maku.ps1 app update -WithBrowser
.EXAMPLE
    .\contrib\maku.ps1 app update -WithBrowser -Force
#>
param(
    [switch]$WithBrowser,
    [string]$Image,
    [int]$Port = 5000,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

# The Dockerfile copies these paths and nothing else, so only a change to one of
# them can change the image. Everything in contrib/ is absent from the image, so
# a pull that only touches tooling needs a restart, not a rebuild.
$imageInputs = @(
    'Dockerfile'
    'docker-entrypoint.sh'
    'requirements.txt'
    'changedetection.py'
    'changedetectionio/'
    'docs/api-spec.yaml'
)

# Whether the image on THIS machine still matches the source in this clone, and
# in one sentence why not.
#
# THE QUESTION IS NOT "DID THIS PULL CHANGE ANYTHING". It used to be: the check
# diffed the pull's own range, $before..$after. So the first run after a sync
# pulled, saw Dockerfile and requirements.txt move, and went to build -- and if
# anything after the pull failed (a build error, a podman that was not up, a
# closed laptop), the NEXT run pulled nothing, diffed an empty range, announced
# "no image inputs changed" and started the old image against the new source.
# Silently, and permanently: every later run agreed with it. A stale deployment
# that reports itself as up to date is worse than one that fails.
#
# So the comparison runs from the commit the image itself carries. Anything that
# leaves that unknowable -- no image, an unreachable podman, an image built
# before the label existed -- is a rebuild, because "cannot prove it is current"
# and "is current" must never take the same branch.
function Get-RebuildDecision([string]$Image, [string[]]$Paths) {
    $builtFrom = Get-ImageRevision $Image
    $result = @{ BuiltFrom = $builtFrom; Changed = @(); Reason = $null }

    if (-not $builtFrom) {
        $result.Reason = "no local image '$Image' carrying a revision label"
    } elseif (-not (Test-CommitPresent $builtFrom)) {
        $result.Reason = "the image was built from $($builtFrom.Substring(0,8)), which is not in this clone"
    } else {
        $result.Changed = @(& git diff --name-only $builtFrom HEAD -- @Paths | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { throw "could not diff $builtFrom..HEAD" }
        if ($result.Changed.Count -gt 0) {
            $result.Reason = "image inputs changed since $($builtFrom.Substring(0,8)):"
        }
    }
    return [pscustomobject]$result
}

# Whether the deployment that is RUNNING still matches what this run would start,
# and in one sentence why not. $null means leave it alone.
#
# Same rule as Get-RebuildDecision above, for the same reason: anything that
# cannot be PROVEN to match restarts, because "cannot tell" and "matches" must
# never take the same branch. A string rather than a {Restart; Reason} pair --
# the reason IS the answer, and a caller that has one always wants to print it.
function Get-RestartDecision([hashtable]$Want) {
    $state = Get-ContainerState (Get-PodmanNames).App
    if (-not $state)                 { return 'nothing is running' }
    if ($state.Status -ne 'running') { return "the container is $($state.Status)" }

    $wantedId = Get-ImageId $Want.Image
    if (-not $wantedId -or $state.Image -ne $wantedId) { return 'the image changed' }

    # Both read back from what Start-AppContainer itself set, so they answer what
    # the container was actually STARTED for -- not what a config file now says.
    if (([bool]$state.Env['PLAYWRIGHT_DRIVER_URL']) -ne $Want.WithBrowser) {
        return $(if ($Want.WithBrowser) { 'it is running without the browser' }
                 else { 'it is running with the browser' })
    }
    if ($state.Env['BASE_URL'] -ne "http://localhost:$($Want.Port)") {
        return "it is published on $($state.Env['BASE_URL'])"
    }
    # Before the comparison, and it does NOT fall through to it. An unreadable
    # start time cannot answer "did contrib/runtime change since?", so saying it
    # did would be inventing a reason. Restarting is still right -- nothing here
    # can prove the deployment is current -- but the reason has to be the real
    # one, and it carries what podman said so it is fixable in one run.
    if (-not $state.StartedAt) {
        return "podman's start time could not be read -- it said: $($state.StartedAtText)"
    }
    if ((Get-RuntimeMtime) -gt $state.StartedAt) {
        return 'contrib/runtime changed since the container started'
    }
    return $null
}

# The newest file under contrib/runtime, in UTC.
#
# That directory is mounted read-only into the container and sitecustomize.py is
# read once at interpreter start, so a pull that touches only tooling changes
# nothing about the image and still needs a restart to take effect.
#
# MTIME AGAINST THE CONTAINER'S START TIME, not a git range. A range is exactly
# the staleness trap described above: one failed run and the next one diffs an
# empty range and calls a stale deployment current. Known cost -- a fresh clone
# stamps every mtime to now, so the first update after one restarts when it did
# not have to. That is the safe direction to be wrong in.
function Get-RuntimeMtime {
    $dir = Join-Path $PSScriptRoot '..\..\runtime'
    if (-not (Test-Path $dir)) { return [datetime]::MinValue }
    $newest = Get-ChildItem $dir -Recurse -File |
              Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $newest) { return [datetime]::MinValue }
    return $newest.LastWriteTimeUtc
}

function Test-CommitPresent([string]$Sha) {
    & git cat-file -e "$Sha^{commit}" 2>$null
    return $LASTEXITCODE -eq 0
}

# A pull that touches contrib/ has just replaced THIS SCRIPT, and PowerShell
# parsed the whole file before its first line ran -- so everything below is the
# version that was on disk when the command started, not the one just fetched.
# Modules are different: Import-Module reads them when it runs, which is after
# the pull. That split is not theoretical. The first run after the podman fixes
# landed printed the NEW module's error message and the OLD script's rebuild
# verdict in the same output, and a reader has no way to tell which half of a
# run is stale.
#
# Re-running is the only way to act on what was just fetched. The guard makes it
# strictly one-shot: the relaunched run's own pull is a no-op, so the condition
# cannot hold a second time.
#
# DOES NOT RETURN when it relaunches -- the child's exit code becomes this run's.
function Restart-IfToolingChanged([string]$From, [string]$To, [hashtable]$Bound) {
    if ($env:MAKU_RELAUNCHED -eq '1' -or $From -eq $To) { return }
    $touched = @(& git diff --name-only $From $To -- 'contrib/' | Where-Object { $_ })
    if ($touched.Count -eq 0) { return }

    Write-Host "The pull updated contrib/ -- re-running with the version just fetched."
    Add-Action 'relaunched' 'the pull replaced contrib/, so the run restarted on the new tooling'
    # Drained HERE, at the hand-off. The record so far belongs to this process;
    # the child keeps its own and prints it itself, so draining is what stops the
    # two from interleaving around the child's output.
    Write-ActionLog

    # A CHILD PROCESS, not '& $PSCommandPath'. The old form re-ran THIS FILE and
    # nothing else, so maku.ps1 -- one frame up, parsed before the pull -- stayed
    # stale. A pull that fixed the dispatcher therefore ran under the broken one,
    # and the reader got a freshly fixed command rendered the old way. Only a new
    # process re-parses everything this function promises to have refreshed.
    #
    # -File, not -Command: -Command does not propagate the script's exit code.
    $entry = Join-Path $PSScriptRoot '..\..\maku.ps1'
    $childArgs = @('-NoProfile', '-File', $entry, 'app', 'update') + (ConvertTo-Tokens $Bound)
    $env:MAKU_RELAUNCHED = '1'
    try { & pwsh @childArgs } finally { Remove-Item Env:\MAKU_RELAUNCHED -ErrorAction SilentlyContinue }
    exit $LASTEXITCODE
}

# A child process takes a command line, so the bound parameters have to be
# flattened back into the tokens they arrived as.
function ConvertTo-Tokens([hashtable]$Bound) {
    $tokens = @()
    foreach ($key in $Bound.Keys) {
        $value = $Bound[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) { $tokens += "-$key" }
        } else {
            $tokens += @("-$key", [string]$value)
        }
    }
    return $tokens
}

Assert-CleanTree
$branch = Get-CurrentBranch
$before = (& git rev-parse HEAD).Trim()

Write-Host "Pulling $branch..."
& git pull --ff-only
if ($LASTEXITCODE -ne 0) {
    throw ("git pull --ff-only failed. This clone has local commits or has diverged " +
           "from its remote; it is meant to only ever follow. Resolve by hand, or re-clone.")
}

$after = (& git rev-parse HEAD).Trim()
if ($before -eq $after) {
    Write-Host "Already up to date at $($after.Substring(0,8))."
} else {
    Write-Host "Updated $($before.Substring(0,8)) -> $($after.Substring(0,8))."
    Add-Action 'pulled' "$($before.Substring(0,8)) -> $($after.Substring(0,8))"
}

# Exits the run when it relaunches, so there is nothing to test here.
Restart-IfToolingChanged $before $after $PSBoundParameters

# After the pull, deliberately. Every path from here ends in podman -- the
# rebuild check reads a label off an image, the start needs it outright -- and an
# absent binary raises CommandNotFoundException, which $ErrorActionPreference
# 'Stop' turns into a terminating error before any exit code can be read, so
# without this the reader gets "the term 'podman' is not recognized" from inside
# a label lookup. It does NOT come first: a broken podman must not stop this
# machine from receiving a fix for the tooling, which is exactly the position a
# deployment box is in when podman is the thing that is broken.
Test-PodmanReady

if ($Image) {
    Write-Host "Deploying $Image -- nothing to build."
} else {
    $decision = Get-RebuildDecision (Get-ImagePin 'AppLocal') $imageInputs
    if ($decision.Reason) {
        Write-Host "Rebuilding -- $($decision.Reason)"
        $decision.Changed | ForEach-Object { Write-Host "    $_" }
        & (Join-Path $PSScriptRoot 'build.ps1')
        if ($LASTEXITCODE -ne 0) { throw "build failed -- not restarting." }
    } else {
        Write-Host "Image is current at $($decision.BuiltFrom.Substring(0,8)) -- reusing it."
    }
}

# What this run WOULD start, so the decision below compares like with like
# rather than comparing a running container against its own defaults.
$want = @{
    Image       = $(if ($Image) { $Image } else { Get-ImagePin 'AppLocal' })
    Port        = $Port
    WithBrowser = [bool]$WithBrowser
}

# -Force first, and short-circuiting: someone who passed it is not asking for an
# opinion, and the inspection costs two podman calls.
$why = if ($Force) { 'asked for with -Force' } else { Get-RestartDecision $want }

if (-not $why) {
    Write-Host "Not restarting -- the deployment already runs this image and topology."
    # Carrying the options back. A bare 'app update -Force' pasted from here
    # would drop -WithBrowser and quietly redeploy the wrong topology.
    $again = @('.\contrib\maku.ps1', 'app', 'update') + (ConvertTo-Tokens $PSBoundParameters) + '-Force'
    Write-Host "To restart anyway:  $($again -join ' ')"
    # Recorded even though nothing changed. "This run decided to do nothing" is
    # the single most useful line in the record when someone asks later why a
    # fix did not take effect.
    Add-Action 'left' "running unchanged -- $($want.Image) on 127.0.0.1:$Port"
    return
}
Write-Host "Restarting -- $why"

# 'app start' clears the previous container, browser container and pod itself,
# so there is nothing to tear down here first.
$startArgs = @{ Port = $Port }
if ($Image)       { $startArgs['Image'] = $Image }
if ($WithBrowser) { $startArgs['WithBrowser'] = $true }

& (Join-Path $PSScriptRoot 'start.ps1') @startArgs
