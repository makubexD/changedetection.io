# The pre-push guard: installing it, and the checks it performs.
#
# WHY IT LIVES UNDER .git/ AND NOT IN THE WORKING TREE. The previous hook looked
# for its checker at contrib/fork/identity.ps1 in the CHECKOUT, and exited 0 when
# it was absent. contrib/ exists only on the release branch, so that exemption --
# written for master, a pristine mirror whose pushes are upstream commits nobody
# here authored -- silently covered every feat/* branch as well. Five of six
# branches, including every branch that carries work, pushed unguarded.
#
# So 'guard enable' copies what the check needs into .git/fork-guard/, which is
# per-clone, never committed, and identical on every branch.

Import-Module (Join-Path $PSScriptRoot 'Repo.psm1')

$script:Marker = 'fork-identity-guard'

$script:HookBody = @'
#!/bin/sh
# fork-identity-guard: installed by  .\contrib\maku.ps1 guard enable
# Remove with:                       .\contrib\maku.ps1 guard disable
# Bypass once (it is recorded in the reflog either way): git push --no-verify
#
# Resolves the checker from .git/, NOT from the working tree, so every branch is
# guarded -- feat/* branches do not carry contrib/ and used to slip through.
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd) || exit 0
guard="$common/fork-guard/check.ps1"

if [ ! -f "$guard" ]; then
    echo "" >&2
    echo "fork identity guard: its copy under .git/fork-guard is missing," >&2
    echo "so this push CANNOT be checked. Refusing rather than passing silently." >&2
    echo "  fix: .\contrib\maku.ps1 guard enable" >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then ps=pwsh; else ps=powershell; fi

# stdin -- the <local ref> <local sha> <remote ref> <remote sha> lines -- flows
# straight through; it is what says WHICH COMMITS are about to be published.
"$ps" -NoProfile -ExecutionPolicy Bypass -File "$guard" -Remote "$1" -Url "$2"
status=$?
if [ $status -ne 0 ]; then
    echo "" >&2
    echo "Push stopped by the fork identity guard (above)." >&2
    echo "Override this one push with: git push --no-verify" >&2
fi
exit $status
'@

function Get-GuardDir  { return (Join-Path (Get-GitCommonDir) 'fork-guard') }
function Get-HookPath  { return (Join-Path (Join-Path (Get-GitCommonDir) 'hooks') 'pre-push') }

# What the check needs to run standalone, with no working tree.
#
# ContribRoot defaults to this module's own parent. That is always right:
# check.ps1 imports Repo/Console/Identity/Auth and never Guard.psm1, so this
# module is only ever loaded from contrib/lib, never from the .git/ copy.
function Get-GuardPayload([string]$ContribRoot = (Split-Path $PSScriptRoot -Parent)) {
    return @(
        @{ From = (Join-Path $ContribRoot 'lib\Repo.psm1');     To = 'Repo.psm1' }
        @{ From = (Join-Path $ContribRoot 'lib\Console.psm1');  To = 'Console.psm1' }
        @{ From = (Join-Path $ContribRoot 'lib\Identity.psm1'); To = 'Identity.psm1' }
        @{ From = (Join-Path $ContribRoot 'lib\Auth.psm1');     To = 'Auth.psm1' }
        @{ From = (Join-Path $ContribRoot 'commands\guard\check.ps1'); To = 'check.ps1' }
    )
}

function Install-Guard([string]$ContribRoot) {
    $hook = Get-HookPath
    $dir  = Split-Path $hook -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ((Test-Path $hook) -and ((Get-Content $hook -Raw) -notmatch $script:Marker)) {
        throw "A pre-push hook this tool did not write already exists at $hook -- leaving it alone."
    }

    $guardDir = Get-GuardDir
    if (-not (Test-Path $guardDir)) { New-Item -ItemType Directory -Path $guardDir -Force | Out-Null }

    foreach ($item in (Get-GuardPayload $ContribRoot)) {
        if (-not (Test-Path $item.From)) { throw "Missing $($item.From) -- cannot install the guard." }
        Copy-Item -Path $item.From -Destination (Join-Path $guardDir $item.To) -Force
    }

    # sh rejects a CRLF script with "bad interpreter", and this file's own line
    # endings depend on how git checked it out.
    [System.IO.File]::WriteAllText($hook, ($script:HookBody -replace "`r`n", "`n"))
    return $hook
}

function Uninstall-Guard {
    $hook = Get-HookPath
    $removed = $false
    if (Test-Path $hook) {
        if ((Get-Content $hook -Raw) -notmatch $script:Marker) {
            throw "The pre-push hook at $hook was not written by this tool -- leaving it alone."
        }
        Remove-Item $hook -Force
        $removed = $true
    }
    $dir = Get-GuardDir
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    return $removed
}

# Do the copies under .git/fork-guard still match the tooling they were taken
# from? They are snapshots taken at 'guard enable' time and never re-sync, so
# editing contrib/lib leaves the guard silently running the previous revision.
#
# Compared against the live sources rather than against a manifest recorded at
# install time: a manifest is a third copy of the same fact, and comparing the
# files themselves also catches a copy that was edited or truncated in place.
#
# A source that is ABSENT is not drift. contrib/ exists only on the release
# branch, so on master and every feat/* branch there is nothing to compare --
# which is the normal state there, not evidence of anything.
# Is every file the check imports actually present under .git/fork-guard? A
# missing one is not drift: check.ps1 cannot even load, so nothing is verified.
# Branch-independent, because it looks only at the .git/ copies.
function Test-GuardComplete {
    $guardDir = Get-GuardDir
    foreach ($item in (Get-GuardPayload)) {
        if (-not (Test-Path -LiteralPath (Join-Path $guardDir $item.To))) { return $false }
    }
    return $true
}

function Test-GuardCurrent {
    $guardDir = Get-GuardDir
    foreach ($item in (Get-GuardPayload)) {
        if (-not (Test-Path -LiteralPath $item.From)) { continue }
        $installed = Join-Path $guardDir $item.To
        if (-not (Test-Path -LiteralPath $installed)) { return $false }
        $source = (Get-FileHash -LiteralPath $item.From  -Algorithm SHA256).Hash
        $copy   = (Get-FileHash -LiteralPath $installed  -Algorithm SHA256).Hash
        if ($source -ne $copy) { return $false }
    }
    return $true
}

# off | foreign | stale | drifted | on.
#
# 'stale' means the check CANNOT RUN: a hook installed by the old tooling points
# at contrib/fork/identity.ps1, which no longer exists, and that hook exits 0
# when its target is missing -- so it passes every push in silence.
#
# 'drifted' is weaker and deliberately so: the check runs and commits really are
# verified, just by an older revision of the logic. It is reported as a warning
# rather than a refusal because every edit to contrib/lib produces it, and a
# refusal that fires constantly during ordinary work is one people learn to
# ignore -- which would cost more than it buys.
function Get-GuardState {
    $hook = Get-HookPath
    if (-not (Test-Path $hook)) { return 'off' }
    $body = Get-Content $hook -Raw
    if ($body -notmatch $script:Marker) { return 'foreign' }
    if ($body -match 'identity\.ps1')   { return 'stale' }
    if (-not (Test-GuardComplete))      { return 'stale' }
    if (-not (Test-GuardCurrent))       { return 'drifted' }
    return 'on'
}

Export-ModuleMember -Function Get-GuardDir, Get-HookPath, Install-Guard, Uninstall-Guard,
                              Get-GuardState, Get-GuardPayload,
                              Test-GuardComplete, Test-GuardCurrent
